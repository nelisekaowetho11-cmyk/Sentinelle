//go:build linux

package main

import (
	"encoding/binary"
	"fmt"
	"sync"
	"sync/atomic"
	"syscall"
)

const (
	soSndBufForce = 32
	soRcvBufForce = 33

	protoIPIP = 4
	protoGRE  = 47
	protoICMP = 1
)

// rawTransport encapsulates frames directly in IP packets. Depending on the
// profile the payload sits behind a bare IP header (bip/ipip), a GRE header, or
// an ICMP echo header. No TCP or UDP port is involved at all, which is the
// whole point: there is no port for a filter to match on.
type rawTransport struct {
	proto    int
	profile  string
	listen   [4]byte
	dst      [4]byte
	iface    string
	icmpType byte
	icmpCode byte
	icmpID   uint16
	sndBuf   int
	rcvBuf   int

	rxFD   int
	rxOnce sync.Once
	mu     sync.Mutex
	tx     []*rawSender
	desc   string
}

func newRawTransport(cfg *Config, c *Crypto) (*rawTransport, error) {
	t := &rawTransport{
		profile:  cfg.Profile,
		iface:    cfg.Interface,
		icmpType: byte(cfg.ICMPType),
		icmpCode: byte(cfg.ICMPCode),
		icmpID:   c.icmpID,
		sndBuf:   cfg.SoSndBuf,
		rcvBuf:   cfg.SoRcvBuf,
	}
	copy(t.listen[:], cfg.listenIP.To4())
	copy(t.dst[:], cfg.dstIP.To4())

	switch cfg.Profile {
	case "icmp":
		t.proto = protoICMP
		t.desc = fmt.Sprintf("icmp (type %d/code %d, id 0x%04x) %s <-> %s",
			cfg.ICMPType, cfg.ICMPCode, t.icmpID, cfg.ListenIP, cfg.DstIP)
	case "ipip":
		t.proto = protoIPIP
		t.desc = fmt.Sprintf("ipip (proto 4) %s <-> %s", cfg.ListenIP, cfg.DstIP)
	case "gre":
		t.proto = protoGRE
		t.desc = fmt.Sprintf("gre (proto 47) %s <-> %s", cfg.ListenIP, cfg.DstIP)
	default: // bip
		t.proto = cfg.IPProto
		t.desc = fmt.Sprintf("bip (raw ip proto %d) %s <-> %s", cfg.IPProto, cfg.ListenIP, cfg.DstIP)
	}

	fd, err := t.socket()
	if err != nil {
		return nil, err
	}
	t.rxFD = fd
	return t, nil
}

func (t *rawTransport) socket() (int, error) {
	fd, err := syscall.Socket(syscall.AF_INET, syscall.SOCK_RAW|syscall.SOCK_CLOEXEC, t.proto)
	if err != nil {
		if err == syscall.EPERM {
			return -1, fmt.Errorf("raw socket for protocol %d: permission denied (run as root, or grant CAP_NET_RAW)", t.proto)
		}
		return -1, fmt.Errorf("raw socket for protocol %d: %v", t.proto, err)
	}

	if t.iface != "" {
		if err := syscall.SetsockoptString(fd, syscall.SOL_SOCKET, syscall.SO_BINDTODEVICE, t.iface); err != nil {
			syscall.Close(fd)
			return -1, fmt.Errorf("SO_BINDTODEVICE %s: %v", t.iface, err)
		}
	}

	setBuf(fd, soRcvBufForce, syscall.SO_RCVBUF, t.rcvBuf, 16<<20)
	setBuf(fd, soSndBufForce, syscall.SO_SNDBUF, t.sndBuf, 4<<20)

	// Bind to our public address so we only see packets addressed to us, then
	// connect to the peer so the kernel filters by source address too and we can
	// use plain read/write instead of recvfrom/sendto.
	if err := syscall.Bind(fd, &syscall.SockaddrInet4{Addr: t.listen}); err != nil {
		syscall.Close(fd)
		return -1, fmt.Errorf("bind raw socket to %d.%d.%d.%d: %v (is listen_ip an address on this host?)",
			t.listen[0], t.listen[1], t.listen[2], t.listen[3], err)
	}
	if err := syscall.Connect(fd, &syscall.SockaddrInet4{Addr: t.dst}); err != nil {
		syscall.Close(fd)
		return -1, fmt.Errorf("connect raw socket to %d.%d.%d.%d: %v",
			t.dst[0], t.dst[1], t.dst[2], t.dst[3], err)
	}
	return fd, nil
}

// setBuf tries the privileged FORCE variant first so we can exceed
// net.core.rmem_max without touching global sysctls, then falls back.
func setBuf(fd, forceOpt, opt, want, def int) {
	if want <= 0 {
		want = def
	}
	if err := syscall.SetsockoptInt(fd, syscall.SOL_SOCKET, forceOpt, want); err == nil {
		return
	}
	_ = syscall.SetsockoptInt(fd, syscall.SOL_SOCKET, opt, want)
}

// Recv reads one packet and strips the outer headers, returning our frame.
// The socket is already connected to the peer, so the kernel has filtered by
// source address and there is no peer to learn.
func (t *rawTransport) Recv(buf []byte) ([]byte, any, error) {
	for {
		n, err := syscall.Read(t.rxFD, buf)
		if err != nil {
			if err == syscall.EINTR {
				continue
			}
			return nil, nil, err
		}
		if n < 20 {
			continue
		}
		// A raw IPv4 socket always hands us the IP header.
		ihl := int(buf[0]&0x0f) * 4
		if ihl < 20 || ihl > n {
			continue
		}
		payload := buf[ihl:n]

		switch t.profile {
		case "icmp":
			if len(payload) < 8 {
				continue
			}
			if payload[0] != t.icmpType || payload[1] != t.icmpCode {
				continue // somebody else's ping
			}
			if binary.BigEndian.Uint16(payload[4:6]) != t.icmpID {
				continue // not ours
			}
			payload = payload[8:]
		case "gre":
			if len(payload) < 4 {
				continue
			}
			payload = payload[4:]
		}

		if len(payload) == 0 {
			continue
		}
		return payload, nil, nil
	}
}

func (t *rawTransport) Confirm(any) {}

func (t *rawTransport) NewSender() (Sender, error) {
	fd, err := t.socket()
	if err != nil {
		return nil, err
	}
	s := &rawSender{fd: fd, profile: t.profile, icmpType: t.icmpType,
		icmpCode: t.icmpCode, icmpID: t.icmpID}
	s.scratch = make([]byte, 65536)

	t.mu.Lock()
	t.tx = append(t.tx, s)
	t.mu.Unlock()
	return s, nil
}

func (t *rawTransport) Describe() string { return t.desc }

// Close is safe to call alongside the owners of the senders: every descriptor
// is closed exactly once, so a number freed here can never be closed again
// after the kernel has handed it to something else.
func (t *rawTransport) Close() error {
	t.rxOnce.Do(func() { syscall.Close(t.rxFD) })

	t.mu.Lock()
	senders := t.tx
	t.mu.Unlock()

	for _, s := range senders {
		s.Close()
	}
	return nil
}

type rawSender struct {
	fd       int
	profile  string
	icmpType byte
	icmpCode byte
	icmpID   uint16
	seq      uint16
	scratch  []byte
	once     sync.Once
	closed   atomic.Bool
}

func (s *rawSender) Send(frame []byte) error {
	if s.closed.Load() {
		return syscall.EBADF
	}
	var out []byte

	switch s.profile {
	case "icmp":
		need := 8 + len(frame)
		if cap(s.scratch) < need {
			s.scratch = make([]byte, need)
		}
		out = s.scratch[:need]
		out[0] = s.icmpType
		out[1] = s.icmpCode
		out[2], out[3] = 0, 0
		binary.BigEndian.PutUint16(out[4:6], s.icmpID)
		s.seq++
		binary.BigEndian.PutUint16(out[6:8], s.seq)
		copy(out[8:], frame)
		// The kernel computes the checksum for ICMPv6 but not for ICMPv4.
		binary.BigEndian.PutUint16(out[2:4], checksum(out))

	case "gre":
		need := 4 + len(frame)
		if cap(s.scratch) < need {
			s.scratch = make([]byte, need)
		}
		out = s.scratch[:need]
		binary.BigEndian.PutUint16(out[0:2], 0)      // no checksum/key/seq
		binary.BigEndian.PutUint16(out[2:4], 0x0800) // inner protocol: IPv4
		copy(out[4:], frame)

	default:
		out = frame
	}

	for {
		_, err := syscall.Write(s.fd, out)
		if err == syscall.EINTR {
			continue
		}
		return err
	}
}

func (s *rawSender) Close() error {
	s.once.Do(func() {
		s.closed.Store(true)
		syscall.Close(s.fd)
	})
	return nil
}

func newTransport(cfg *Config, c *Crypto) (Transport, error) {
	if cfg.Profile == "udp" {
		return newUDPTransport(cfg)
	}
	return newRawTransport(cfg, c)
}
