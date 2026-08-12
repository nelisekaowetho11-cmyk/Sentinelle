package main

import (
	"errors"
	"fmt"
	"io"
	"net"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
)

// PortMap is one "listen here, deliver there" rule.
type PortMap struct {
	Listen int
	Target int
}

// parseMappings accepts the same spellings the original tool used:
//
//	443            listen 443 -> peer 443
//	443=5000       listen 443 -> peer 5000
//	443-450        listen each of 443..450 -> same port on peer
//	443-450:5201   listen each of 443..450 -> peer 5201
func parseMappings(entries []string) ([]PortMap, error) {
	var out []PortMap
	seen := map[int]bool{}

	add := func(l, t int) error {
		if l < 1 || l > 65535 || t < 1 || t > 65535 {
			return fmt.Errorf("port %d/%d out of range", l, t)
		}
		if seen[l] {
			return fmt.Errorf("listen port %d is mapped twice", l)
		}
		seen[l] = true
		out = append(out, PortMap{Listen: l, Target: t})
		return nil
	}

	for _, raw := range entries {
		e := strings.TrimSpace(raw)
		if e == "" {
			continue
		}

		// range forms
		if strings.Contains(e, "-") {
			rangePart, targetPart := e, ""
			if i := strings.Index(e, ":"); i >= 0 {
				rangePart, targetPart = e[:i], e[i+1:]
			}
			bounds := strings.SplitN(rangePart, "-", 2)
			lo, err1 := strconv.Atoi(strings.TrimSpace(bounds[0]))
			hi, err2 := strconv.Atoi(strings.TrimSpace(bounds[1]))
			if err1 != nil || err2 != nil || lo > hi {
				return nil, fmt.Errorf("bad port range %q", e)
			}
			target := 0
			if targetPart != "" {
				t, err := strconv.Atoi(strings.TrimSpace(targetPart))
				if err != nil {
					return nil, fmt.Errorf("bad target port in %q", e)
				}
				target = t
			}
			for p := lo; p <= hi; p++ {
				dst := p
				if target != 0 {
					dst = target
				}
				if err := add(p, dst); err != nil {
					return nil, err
				}
			}
			continue
		}

		if i := strings.Index(e, "="); i >= 0 {
			l, err1 := strconv.Atoi(strings.TrimSpace(e[:i]))
			t, err2 := strconv.Atoi(strings.TrimSpace(e[i+1:]))
			if err1 != nil || err2 != nil {
				return nil, fmt.Errorf("bad mapping %q", e)
			}
			if err := add(l, t); err != nil {
				return nil, err
			}
			continue
		}

		p, err := strconv.Atoi(e)
		if err != nil {
			return nil, fmt.Errorf("bad mapping %q", e)
		}
		if err := add(p, p); err != nil {
			return nil, err
		}
	}
	return out, nil
}

// splitRule tokenises an `iptables -S` line for the netfilter forwarder.
// Comments come back quoted, so a plain Fields() split would hand iptables an
// argument with literal quote characters in it and the delete would silently
// match nothing.
func splitRule(line string) []string {
	var out []string
	var cur strings.Builder
	inQuote := false

	flush := func() {
		if cur.Len() > 0 {
			out = append(out, cur.String())
			cur.Reset()
		}
	}
	for i := 0; i < len(line); i++ {
		switch c := line[i]; c {
		case '"':
			inQuote = !inQuote
			// An empty quoted string is still a real argument.
			if !inQuote && cur.Len() == 0 {
				out = append(out, "")
			}
		case ' ', '\t':
			if inQuote {
				cur.WriteByte(c)
			} else {
				flush()
			}
		default:
			cur.WriteByte(c)
		}
	}
	flush()
	return out
}

// bindError turns "address already in use" into something you can act on. This
// is the check that actually matters for port conflicts: it runs against the
// live system at start-up, rather than guessing from config text.
func bindError(proto string, port int, err error) error {
	if errors.Is(err, syscall.EADDRINUSE) {
		return fmt.Errorf("cannot listen on %s :%d: already in use. "+
			"Find the owner with:  ss -lntup 'sport = :%d'  — if it is the old "+
			"tunnel, stop its service (systemctl disable --now <unit>) rather "+
			"than killing the process, which a supervisor would just restart",
			proto, port, port)
	}
	return fmt.Errorf("listen %s :%d: %v", proto, port, err)
}

// Forwarder proxies public ports across the tunnel to the peer's tunnel IP.
type Forwarder struct {
	peer      net.IP
	maps      []PortMap
	stats     *Stats
	log       *Logger
	idle      time.Duration
	listeners []io.Closer
	mu        sync.Mutex
	closed    atomic.Bool
	wg        sync.WaitGroup
}

func NewForwarder(peer net.IP, maps []PortMap, st *Stats, log *Logger) *Forwarder {
	return &Forwarder{peer: peer, maps: maps, stats: st, log: log, idle: 90 * time.Second}
}

func (f *Forwarder) Start() error {
	for _, m := range f.maps {
		if err := f.startTCP(m); err != nil {
			return err
		}
		if err := f.startUDP(m); err != nil {
			return err
		}
		f.log.Infof("forward %d -> %s:%d (tcp+udp)", m.Listen, f.peer, m.Target)
	}
	return nil
}

func (f *Forwarder) track(c io.Closer) {
	f.mu.Lock()
	f.listeners = append(f.listeners, c)
	f.mu.Unlock()
}

func (f *Forwarder) Close() {
	if f.closed.Swap(true) {
		return
	}
	f.mu.Lock()
	for _, l := range f.listeners {
		l.Close()
	}
	f.listeners = nil
	f.mu.Unlock()
}

func (f *Forwarder) startTCP(m PortMap) error {
	ln, err := net.Listen("tcp", ":"+strconv.Itoa(m.Listen))
	if err != nil {
		return bindError("tcp", m.Listen, err)
	}
	f.track(ln)

	target := net.JoinHostPort(f.peer.String(), strconv.Itoa(m.Target))
	f.wg.Add(1)
	go func() {
		defer f.wg.Done()
		for {
			conn, err := ln.Accept()
			if err != nil {
				if f.closed.Load() {
					return
				}
				if ne, ok := err.(net.Error); ok && ne.Timeout() {
					continue
				}
				return
			}
			go f.pipeTCP(conn, target)
		}
	}()
	return nil
}

func (f *Forwarder) pipeTCP(client net.Conn, target string) {
	f.stats.TCPOpen.Add(1)
	f.stats.TCPActive.Add(1)
	defer func() {
		f.stats.TCPActive.Add(-1)
		client.Close()
	}()

	if tc, ok := client.(*net.TCPConn); ok {
		tc.SetNoDelay(true)
		tc.SetKeepAlive(true)
		tc.SetKeepAlivePeriod(30 * time.Second)
	}

	upstream, err := net.DialTimeout("tcp", target, 10*time.Second)
	if err != nil {
		f.stats.TCPFailed.Add(1)
		f.log.Debugf("dial %s: %v", target, err)
		return
	}
	defer upstream.Close()
	if tc, ok := upstream.(*net.TCPConn); ok {
		tc.SetNoDelay(true)
		tc.SetKeepAlive(true)
		tc.SetKeepAlivePeriod(30 * time.Second)
	}

	// Both sides are *net.TCPConn, so io.Copy lands on TCPConn.ReadFrom and the
	// kernel splices the sockets together: no userspace copy at all.
	done := make(chan struct{}, 2)
	go func() {
		n, _ := io.Copy(upstream, client)
		f.stats.FwdBytesUp.Add(uint64(n))
		if tc, ok := upstream.(*net.TCPConn); ok {
			tc.CloseWrite()
		}
		done <- struct{}{}
	}()
	go func() {
		n, _ := io.Copy(client, upstream)
		f.stats.FwdBytesDown.Add(uint64(n))
		if tc, ok := client.(*net.TCPConn); ok {
			tc.CloseWrite()
		}
		done <- struct{}{}
	}()
	<-done
	<-done
}

// udpSession is one client's flow, held open by activity.
type udpSession struct {
	conn *net.UDPConn
	last atomic.Int64
}

func (f *Forwarder) startUDP(m PortMap) error {
	pc, err := net.ListenUDP("udp", &net.UDPAddr{Port: m.Listen})
	if err != nil {
		return bindError("udp", m.Listen, err)
	}
	f.track(pc)
	_ = pc.SetReadBuffer(4 << 20)
	_ = pc.SetWriteBuffer(4 << 20)

	target := &net.UDPAddr{IP: f.peer, Port: m.Target}
	sessions := sync.Map{} // client addr string -> *udpSession

	f.wg.Add(1)
	go func() {
		defer f.wg.Done()
		buf := make([]byte, 65535)
		for {
			n, client, err := pc.ReadFromUDP(buf)
			if err != nil {
				if f.closed.Load() {
					return
				}
				continue
			}

			key := client.String()
			var sess *udpSession
			if v, ok := sessions.Load(key); ok {
				sess = v.(*udpSession)
			} else {
				up, err := net.DialUDP("udp", nil, target)
				if err != nil {
					f.stats.UDPFailed.Add(1)
					continue
				}
				sess = &udpSession{conn: up}
				actual, loaded := sessions.LoadOrStore(key, sess)
				if loaded {
					up.Close()
					sess = actual.(*udpSession)
				} else {
					f.stats.UDPActive.Add(1)
					go f.udpReturn(pc, sess, client, key, &sessions)
				}
			}

			sess.last.Store(time.Now().UnixNano())
			if _, err := sess.conn.Write(buf[:n]); err == nil {
				f.stats.FwdBytesUp.Add(uint64(n))
			}
		}
	}()
	return nil
}

// udpReturn carries replies back to the client and reaps the flow once idle.
func (f *Forwarder) udpReturn(pc *net.UDPConn, sess *udpSession, client *net.UDPAddr, key string, sessions *sync.Map) {
	defer func() {
		sess.conn.Close()
		sessions.Delete(key)
		f.stats.UDPActive.Add(-1)
	}()

	buf := make([]byte, 65535)
	for {
		_ = sess.conn.SetReadDeadline(time.Now().Add(f.idle))
		n, err := sess.conn.Read(buf)
		if err != nil {
			if ne, ok := err.(net.Error); ok && ne.Timeout() {
				last := time.Unix(0, sess.last.Load())
				if time.Since(last) >= f.idle {
					return
				}
				continue
			}
			return
		}
		sess.last.Store(time.Now().UnixNano())
		if _, err := pc.WriteToUDP(buf[:n], client); err == nil {
			f.stats.FwdBytesDown.Add(uint64(n))
		}
	}
}
