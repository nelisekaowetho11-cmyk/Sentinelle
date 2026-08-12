package main

import (
	"fmt"
	"net"
	"sync"
	"sync/atomic"
)

// Transport moves opaque frames between the two endpoints.
//
// Receiving is single-socket by design: a Linux raw socket delivers a copy of
// every matching packet to *every* open raw socket, so a pool of receive
// sockets would process each packet N times. Instead one reader feeds a pool of
// decrypt workers. Sending has no such constraint, so each worker gets its own
// socket and never contends on a lock.
// Recv returns the frame plus an opaque source token. Confirm is called only
// after the frame has authenticated, which is what lets the UDP profile learn a
// roaming peer without letting a spoofed packet redirect the tunnel.
type Transport interface {
	Recv(buf []byte) ([]byte, any, error)
	Confirm(src any)
	NewSender() (Sender, error)
	Describe() string
	Close() error
}

type Sender interface {
	Send(frame []byte) error
	Close() error
}

// ---------- UDP ----------

// udpTransport is the fallback when raw sockets are unavailable (some
// container/VPS setups) or when the operator wants a plain UDP profile.
// The server learns its peer from the first authenticated packet, so a client
// behind NAT or on a dynamic address still works.
type udpTransport struct {
	conn   *net.UDPConn
	peer   atomic.Pointer[net.UDPAddr]
	server bool
	desc   string
	once   sync.Once
}

func newUDPTransport(cfg *Config) (*udpTransport, error) {
	var laddr *net.UDPAddr
	if cfg.isServer() {
		laddr = &net.UDPAddr{IP: cfg.listenIP, Port: cfg.UDPPort}
	} else {
		laddr = &net.UDPAddr{Port: 0}
	}

	conn, err := net.ListenUDP("udp4", laddr)
	if err != nil {
		return nil, fmt.Errorf("udp listen %v: %v", laddr, err)
	}

	t := &udpTransport{conn: conn, server: cfg.isServer()}
	if cfg.dstIP != nil {
		t.peer.Store(&net.UDPAddr{IP: cfg.dstIP, Port: cfg.UDPPort})
	}
	if cfg.isServer() {
		t.desc = fmt.Sprintf("udp listening on %s:%d", cfg.listenIP, cfg.UDPPort)
	} else {
		t.desc = fmt.Sprintf("udp to %s:%d", cfg.dstIP, cfg.UDPPort)
	}

	if cfg.SoRcvBuf > 0 {
		_ = conn.SetReadBuffer(cfg.SoRcvBuf)
	} else {
		_ = conn.SetReadBuffer(16 << 20)
	}
	if cfg.SoSndBuf > 0 {
		_ = conn.SetWriteBuffer(cfg.SoSndBuf)
	} else {
		_ = conn.SetWriteBuffer(4 << 20)
	}
	return t, nil
}

func (t *udpTransport) Recv(buf []byte) ([]byte, any, error) {
	n, addr, err := t.conn.ReadFromUDP(buf)
	if err != nil {
		return nil, nil, err
	}
	return buf[:n], addr, nil
}

// Confirm records a roaming peer, but only for frames that already passed
// authentication, so an off-path spoofer cannot steer our traffic at them.
func (t *udpTransport) Confirm(src any) {
	if !t.server {
		return
	}
	addr, ok := src.(*net.UDPAddr)
	if !ok || addr == nil {
		return
	}
	cur := t.peer.Load()
	if cur == nil || !cur.IP.Equal(addr.IP) || cur.Port != addr.Port {
		t.peer.Store(addr)
	}
}

func (t *udpTransport) NewSender() (Sender, error) { return &udpSender{t: t}, nil }
func (t *udpTransport) Describe() string           { return t.desc }
func (t *udpTransport) Close() error {
	t.once.Do(func() { t.conn.Close() })
	return nil
}

type udpSender struct{ t *udpTransport }

func (s *udpSender) Send(frame []byte) error {
	peer := s.t.peer.Load()
	if peer == nil {
		return errNoPeer
	}
	_, err := s.t.conn.WriteToUDP(frame, peer)
	return err
}
func (s *udpSender) Close() error { return nil }

var errNoPeer = fmt.Errorf("peer address not yet known")

// checksum is the standard internet checksum (RFC 1071).
func checksum(b []byte) uint16 {
	var sum uint32
	i := 0
	for ; i+1 < len(b); i += 2 {
		sum += uint32(b[i])<<8 | uint32(b[i+1])
	}
	if i < len(b) {
		sum += uint32(b[i]) << 8
	}
	for sum>>16 != 0 {
		sum = (sum & 0xffff) + (sum >> 16)
	}
	return ^uint16(sum)
}
