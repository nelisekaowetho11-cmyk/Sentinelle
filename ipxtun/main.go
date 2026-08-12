//go:build linux

package main

import (
	"encoding/binary"
	"flag"
	"fmt"
	"os"
	"os/signal"
	"runtime"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
)

const version = "1.0.0"

type pkt struct {
	buf  []byte
	data []byte
	src  any
}

type Engine struct {
	cfg *Config
	log *Logger
	st  *Stats
	tun *Tun
	tr  Transport
	cr  *Crypto

	session  uint32
	senders  []Sender
	kaSender Sender

	rxCh   chan *pkt
	freeCh chan *pkt
	pingCh chan uint64
	pongCh chan uint64

	quit      chan struct{}
	closeOnce sync.Once
	fatalCh   chan struct{}
	fatalOnce sync.Once
	fatalErr  atomic.Value
	wg        sync.WaitGroup

	fwd    *Forwarder
	ipt    *IPTables
	health *HealthServer
}

func main() {
	var (
		cfgPath = flag.String("c", "", "path to the TOML config file")
		showVer = flag.Bool("v", false, "print version and exit")
		genPSK  = flag.Bool("genpsk", false, "generate a fresh pre-shared key and exit")
		check   = flag.Bool("check", false, "validate the config and exit")
	)
	flag.Parse()

	if *showVer {
		fmt.Printf("ipxtun %s (%s %s/%s)\n", version, runtime.Version(), runtime.GOOS, runtime.GOARCH)
		return
	}
	if *genPSK {
		psk, err := generatePSK()
		if err != nil {
			fmt.Fprintln(os.Stderr, "entropy failure:", err)
			os.Exit(1)
		}
		fmt.Println(psk)
		return
	}
	if *cfgPath == "" {
		fmt.Fprintln(os.Stderr, "usage: ipxtun -c /etc/ipxtun/iran.toml")
		flag.PrintDefaults()
		os.Exit(2)
	}

	cfg, err := LoadConfig(*cfgPath)
	if err != nil {
		fmt.Fprintln(os.Stderr, "config error:", err)
		os.Exit(1)
	}
	if *check {
		fmt.Printf("config OK: %s mode, %s profile, mtu %d (%d bytes of encapsulation overhead)\n",
			cfg.Mode, cfg.Profile, cfg.MTU, cfg.encapOverhead())
		return
	}

	if os.Geteuid() != 0 {
		fmt.Fprintln(os.Stderr, "ipxtun needs root: it creates a TUN device and opens raw sockets")
		os.Exit(1)
	}

	eng, err := NewEngine(cfg)
	if err != nil {
		fmt.Fprintln(os.Stderr, "startup failed:", err)
		os.Exit(1)
	}
	if err := eng.Run(); err != nil {
		fmt.Fprintln(os.Stderr, "runtime error:", err)
		eng.Close()
		os.Exit(1)
	}
}

func NewEngine(cfg *Config) (*Engine, error) {
	log := NewLogger(cfg.LogLevel)
	st := NewStats()

	e := &Engine{
		cfg:     cfg,
		log:     log,
		st:      st,
		session: randSession(),
		quit:    make(chan struct{}),
		fatalCh: make(chan struct{}),
		pingCh:  make(chan uint64, 16),
		pongCh:  make(chan uint64, 16),
	}

	log.Infof("ipxtun %s starting: %s mode, profile %s, session %08x", version, cfg.Mode, cfg.Profile, e.session)

	if cfg.AutoTuning {
		applyTuning(cfg.TuningProfile, log)
	}

	var err error
	if e.cr, err = NewCrypto(cfg); err != nil {
		return nil, err
	}
	if !cfg.EnableEncryption {
		log.Warnf("encryption is DISABLED; traffic is authenticated by nothing and readable by anyone on the path")
	}

	// Sanity check the addressing before we touch the network.
	if cfg.Interface != "" {
		if have := hostIPForInterface(cfg.Interface); have != "" && have != cfg.ListenIP {
			log.Warnf("listen_ip is %s but %s carries %s; if the tunnel stays silent this is why",
				cfg.ListenIP, cfg.Interface, have)
		}
	}

	if e.tun, err = OpenTun(cfg.TunName, cfg.MTU, cfg.Workers); err != nil {
		return nil, err
	}
	if err := e.tun.Configure(cfg.LocalAddr, cfg.MTU, 10000); err != nil {
		e.tun.Close()
		return nil, err
	}
	log.Infof("interface %s up: %s -> peer %s, mtu %d, %d queue(s)",
		cfg.TunName, cfg.LocalAddr, cfg.peerIP, cfg.MTU, e.tun.Queues())

	if e.tr, err = newTransport(cfg, e.cr); err != nil {
		e.tun.Close()
		return nil, err
	}
	log.Infof("transport: %s", e.tr.Describe())

	if cfg.Profile == "icmp" && cfg.ICMPType == 8 {
		log.Warnf("icmp_type 8 makes the peer kernel answer every packet with a real echo reply, doubling traffic; type 0 is the quiet choice")
	}

	for i := 0; i < cfg.Workers; i++ {
		s, err := e.tr.NewSender()
		if err != nil {
			e.closeAll()
			return nil, err
		}
		e.senders = append(e.senders, s)
	}
	if e.kaSender, err = e.tr.NewSender(); err != nil {
		e.closeAll()
		return nil, err
	}

	pool := cfg.ChannelSize
	if pool < 256 {
		pool = 256
	}
	if pool > 4096 {
		pool = 4096
	}
	bufSize := cfg.MTU + 1024
	if bufSize < 4096 {
		bufSize = 4096
	}
	e.rxCh = make(chan *pkt, pool)
	e.freeCh = make(chan *pkt, pool)
	for i := 0; i < pool; i++ {
		e.freeCh <- &pkt{buf: make([]byte, bufSize)}
	}

	if e.health, err = NewHealthServer(cfg, st, log, e.tr.Describe()); err != nil {
		e.closeAll()
		return nil, err
	}

	if len(cfg.Mapping) > 0 && cfg.Forwarder != "none" {
		maps, err := parseMappings(cfg.Mapping)
		if err != nil {
			e.closeAll()
			return nil, err
		}
		if cfg.Forwarder == "iptables" {
			e.ipt = NewIPTables(cfg.peerIP, "ipxtun-"+cfg.TunName, log)
			if err := e.ipt.Apply(maps); err != nil {
				e.closeAll()
				return nil, err
			}
		} else {
			e.fwd = NewForwarder(cfg.peerIP, maps, st, log)
			if err := e.fwd.Start(); err != nil {
				e.closeAll()
				return nil, err
			}
		}
	}

	return e, nil
}

func (e *Engine) Run() error {
	e.health.Start()

	// Uplink: one goroutine per TUN queue. The kernel hashes flows across the
	// queues, so these run genuinely in parallel with no shared state.
	for i := 0; i < e.cfg.Workers; i++ {
		e.wg.Add(1)
		go e.txLoop(i)
	}

	// Downlink: a single reader (raw sockets copy each packet to every open
	// socket, so a second reader would duplicate work) feeding a decrypt pool.
	e.wg.Add(1)
	go e.rxReader()
	for i := 0; i < e.cfg.Workers; i++ {
		e.wg.Add(1)
		go e.rxWorker(i)
	}

	e.wg.Add(1)
	go e.heartbeat()
	e.wg.Add(1)
	go e.monitor()

	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGINT, syscall.SIGTERM)

	var err error
	select {
	case s := <-sig:
		e.log.Infof("signal %v received, shutting down", s)
	case <-e.fatalCh:
		// Exiting is deliberate: a dead datapath is worse than a restart,
		// because the process would still be up while carrying no traffic.
		if v, ok := e.fatalErr.Load().(error); ok {
			err = v
		}
	case <-e.quit:
	}

	e.Close()
	return err
}

// fatal marks the datapath as unrecoverable and unblocks Run so the process can
// exit and be restarted by its supervisor.
func (e *Engine) fatal(err error) {
	e.fatalOnce.Do(func() {
		e.fatalErr.Store(err)
		e.log.Errorf("unrecoverable: %v", err)
		close(e.fatalCh)
	})
}

// txLoop reads plaintext IP packets off the TUN queue, seals them and puts them
// on the wire.
func (e *Engine) txLoop(id int) {
	defer e.wg.Done()
	runtime.LockOSThread()

	cd := newCodec(e.cr, e.session, id, e.cfg.Padding, e.cfg.MTU)
	sender := e.senders[id]
	in := make([]byte, e.cfg.MTU+64)
	out := make([]byte, e.cfg.MTU+frameOverhead+e.cfg.Padding+128)

	softErrs := 0
	for {
		n, err := e.tun.Read(id, in)
		if err != nil {
			if e.stopping() || fatalErr(err) {
				return
			}
			if transientErr(err) {
				continue
			}
			e.fatal(fmt.Errorf("tun read (queue %d): %w", id, err))
			return
		}
		if n <= 0 {
			continue
		}

		frame, err := cd.Seal(out, ptData, in[:n])
		if err != nil {
			e.st.TxErrors.Add(1)
			continue
		}
		if err := sender.Send(frame); err != nil {
			e.st.TxErrors.Add(1)
			switch {
			case err == errNoPeer:
				e.log.Noisyf("dropping packet: peer address not learned yet")
			case transientErr(err):
				// Same ICMP story as the receive path; the peer is unreachable
				// right now, which is not our problem to solve.
				softErrs++
				if softErrs == 1 || softErrs%1000 == 0 {
					e.log.Warnf("send failed: %v (peer unreachable; will keep trying)", err)
				}
			default:
				e.log.Noisyf("send failed: %v", err)
			}
			continue
		}
		softErrs = 0
		e.st.TxPackets.Add(1)
		e.st.TxBytes.Add(uint64(n))
	}
}

func (e *Engine) rxReader() {
	defer e.wg.Done()
	runtime.LockOSThread()

	softErrs := 0
	for {
		var p *pkt
		select {
		case p = <-e.freeCh:
		case <-e.quit:
			return
		default:
			// Decrypt workers are behind. We block rather than allocate, which
			// pushes back onto the socket buffer; a persistent count here means
			// channel_size or workers is too low for the offered load.
			e.st.PoolStalls.Add(1)
			e.log.Noisyf("receive pool exhausted, stalling (raise channel_size or workers)")
			select {
			case p = <-e.freeCh:
			case <-e.quit:
				return
			}
		}

		data, src, err := e.tr.Recv(p.buf)
		if err != nil {
			e.freeCh <- p
			if e.stopping() || fatalErr(err) {
				return
			}
			e.st.RxErrors.Add(1)

			if transientErr(err) {
				// Nearly always an ICMP error the far end queued against our
				// socket - "protocol unreachable" while the peer is not yet
				// running, for instance. It says nothing about our ability to
				// keep receiving, so carry on.
				softErrs++
				if softErrs == 1 || softErrs%1000 == 0 {
					e.log.Warnf("transport read: %v (peer may not be up yet; still listening)", err)
				}
				continue
			}

			e.fatal(fmt.Errorf("transport read: %w", err))
			return
		}
		softErrs = 0
		p.data = data
		p.src = src

		select {
		case e.rxCh <- p:
		case <-e.quit:
			return
		}
	}
}

// rxWorker authenticates a frame and hands the inner packet to the kernel.
func (e *Engine) rxWorker(id int) {
	defer e.wg.Done()
	runtime.LockOSThread()

	cd := newCodec(e.cr, e.session, id, 0, e.cfg.MTU)
	out := make([]byte, e.cfg.MTU+1024)

	for {
		var p *pkt
		select {
		case p = <-e.rxCh:
		case <-e.quit:
			return
		}

		typ, session, counter, plain, err := cd.Open(out, p.data)
		if err != nil {
			e.st.AuthFailed.Add(1)
			e.log.Noisyf("dropped unauthenticated frame: %v", err)
			e.freeCh <- p
			continue
		}

		// Replay protection is per peer session, so a peer restart (new random
		// session id) starts from a clean window instead of stalling.
		if e.cr.enabled && !e.cr.replay(session).accept(counter) {
			e.st.ReplayDrops.Add(1)
			e.log.Noisyf("dropped replayed frame (session %08x counter %d)", session, counter)
			e.freeCh <- p
			continue
		}

		e.tr.Confirm(p.src)
		e.st.LastRxUnix.Store(time.Now().Unix())
		e.st.RxPackets.Add(1)
		e.st.RxBytes.Add(uint64(len(plain)))

		switch typ {
		case ptData:
			if len(plain) == 0 {
				break
			}
			if len(plain) > e.cfg.MTU {
				// The peer is sending larger frames than we agreed on, which
				// means the two ends disagree about mtu. The kernel still
				// accepts it, but it is worth surfacing.
				e.st.Oversize.Add(1)
			}
			if _, err := e.tun.Write(id, plain); err != nil {
				e.st.TunDrops.Add(1)
				e.log.Noisyf("tun write: %v", err)
			}
		case ptPing:
			if len(plain) >= 8 {
				select {
				case e.pingCh <- binary.BigEndian.Uint64(plain[:8]):
				default:
				}
			}
		case ptPong:
			if len(plain) >= 8 {
				select {
				case e.pongCh <- binary.BigEndian.Uint64(plain[:8]):
				default:
				}
			}
		}

		e.freeCh <- p
	}
}

// heartbeat keeps NAT bindings warm and measures round-trip time. There is no
// session to lose here: the tunnel is stateless, so a peer that goes away and
// comes back simply starts being heard again.
func (e *Engine) heartbeat() {
	defer e.wg.Done()

	cd := newCodec(e.cr, e.session, e.cfg.Workers, 0, e.cfg.MTU)
	out := make([]byte, 256)
	var ts [8]byte

	// Hold our own reference: shutdown tears down the engine's fields while this
	// goroutine may still be mid-send.
	sender := e.kaSender

	send := func(typ byte, stamp uint64) {
		binary.BigEndian.PutUint64(ts[:], stamp)
		frame, err := cd.Seal(out, typ, ts[:])
		if err != nil {
			return
		}
		if err := sender.Send(frame); err != nil && err != errNoPeer {
			e.log.Noisyf("heartbeat send: %v", err)
		}
	}

	tick := time.NewTicker(time.Duration(e.cfg.HeartbeatInterval) * time.Second)
	defer tick.Stop()

	send(ptPing, uint64(time.Now().UnixNano()))

	for {
		select {
		case <-tick.C:
			send(ptPing, uint64(time.Now().UnixNano()))
		case stamp := <-e.pingCh:
			send(ptPong, stamp)
		case stamp := <-e.pongCh:
			rtt := time.Since(time.Unix(0, int64(stamp)))
			if rtt > 0 && rtt < time.Minute {
				e.st.PeerRTTMicro.Store(rtt.Microseconds())
			}
		case <-e.quit:
			return
		}
	}
}

// monitor tracks peer liveness for the health endpoint and the log.
func (e *Engine) monitor() {
	defer e.wg.Done()

	tick := time.NewTicker(time.Second)
	defer tick.Stop()
	timeout := time.Duration(e.cfg.HeartbeatTimeout) * time.Second

	for {
		select {
		case <-tick.C:
			last := e.st.LastRxUnix.Load()
			alive := last != 0 && time.Since(time.Unix(last, 0)) < timeout
			was := e.st.PeerUp.Swap(alive)
			if alive && !was {
				e.st.PeerFlaps.Add(1)
				e.log.Infof("peer %s reachable (rtt %.1f ms)", e.cfg.peerIP,
					float64(e.st.PeerRTTMicro.Load())/1000)
			}
			if !alive && was {
				e.log.Warnf("peer %s silent for %s; tunnel keeps listening and will resume on its own",
					e.cfg.peerIP, timeout)
			}
		case <-e.quit:
			return
		}
	}
}

func (e *Engine) stopping() bool {
	select {
	case <-e.quit:
		return true
	default:
		return false
	}
}

func (e *Engine) Close() {
	e.closeOnce.Do(func() {
		close(e.quit)
		e.closeAll()

		done := make(chan struct{})
		go func() { e.wg.Wait(); close(done) }()
		select {
		case <-done:
		case <-time.After(3 * time.Second):
		}
		e.log.Infof("stopped: tx %d packets / %d bytes, rx %d packets / %d bytes",
			e.st.TxPackets.Load(), e.st.TxBytes.Load(), e.st.RxPackets.Load(), e.st.RxBytes.Load())
	})
}

// closeAll releases every resource we may have taken. Safe to call on a
// partially constructed engine.
func (e *Engine) closeAll() {
	if e.fwd != nil {
		e.fwd.Close()
	}
	if e.ipt != nil {
		e.ipt.Cleanup()
	}
	if e.health != nil {
		e.health.Close()
	}
	// The fields are deliberately left in place. Worker goroutines hold their
	// own references and are still winding down; clearing these would race them
	// into a nil dereference for no benefit, since the process is exiting.
	for _, s := range e.senders {
		s.Close()
	}
	if e.kaSender != nil {
		e.kaSender.Close()
	}
	if e.tr != nil {
		e.tr.Close()
	}
	if e.tun != nil {
		e.tun.Close()
	}
}
