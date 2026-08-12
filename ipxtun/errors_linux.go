//go:build linux

package main

import (
	"errors"
	"net"
	"syscall"
)

// transientErr reports whether a socket error is a passing condition rather
// than a reason to tear down the datapath.
//
// The important case is ICMP. A connected raw socket has its ICMP errors
// delivered as a queued socket error, so the *next* read or write fails with
// something that describes the peer, not us. The classic one is ENOPROTOOPT,
// which is how Linux spells "the far end sent ICMP protocol unreachable" —
// exactly what happens while the other side is not running yet. Tearing the
// tunnel down for that would make a stateless design behave like a stateful
// one, dying every time the peer restarts.
func transientErr(err error) bool {
	if err == nil {
		return false
	}

	var errno syscall.Errno
	if errors.As(err, &errno) {
		switch errno {
		case syscall.ENOPROTOOPT, // ICMP protocol unreachable
			syscall.ECONNREFUSED, // ICMP port unreachable
			syscall.EHOSTUNREACH, // ICMP host unreachable
			syscall.ENETUNREACH,  // ICMP network unreachable
			syscall.EHOSTDOWN,    // ICMP host isolated
			syscall.ENETDOWN,     // interface flapped
			syscall.ENONET,       // host not on the network
			syscall.EPROTO,       // protocol error reported by ICMP
			syscall.EMSGSIZE,     // ICMP fragmentation needed
			syscall.ETIMEDOUT,    // ICMP transit timeout
			syscall.ENOBUFS,      // momentary memory pressure
			syscall.EAGAIN,       // nothing ready
			syscall.EINTR:        // interrupted by a signal
			return true
		}
		return false
	}

	// A deadline expiring is never fatal.
	var ne net.Error
	if errors.As(err, &ne) && ne.Timeout() {
		return true
	}
	return false
}

// fatalErr reports whether an error means the file descriptor is gone, which is
// what shutdown looks like from inside a blocking read.
func fatalErr(err error) bool {
	var errno syscall.Errno
	if errors.As(err, &errno) {
		switch errno {
		case syscall.EBADF, syscall.ENOTSOCK, syscall.EPIPE:
			return true
		}
	}
	return errors.Is(err, net.ErrClosed)
}
