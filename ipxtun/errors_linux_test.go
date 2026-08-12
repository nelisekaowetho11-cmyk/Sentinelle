//go:build linux

package main

import (
	"errors"
	"fmt"
	"net"
	"os"
	"syscall"
	"testing"
)

// Regression test for the failure seen on the first live run: the Iran side
// sent a heartbeat before the Kharej side was up, the peer's kernel answered
// with ICMP protocol-unreachable, Linux surfaced it as ENOPROTOOPT on the next
// read, and the receive loop treated it as fatal and stopped.
func TestICMPErrorsAreNotFatal(t *testing.T) {
	icmpDerived := []syscall.Errno{
		syscall.ENOPROTOOPT, // peer has no listener on this IP protocol
		syscall.ECONNREFUSED,
		syscall.EHOSTUNREACH,
		syscall.ENETUNREACH,
		syscall.EHOSTDOWN,
		syscall.ENETDOWN,
		syscall.EPROTO,
		syscall.EMSGSIZE,
		syscall.ETIMEDOUT,
		syscall.ENOBUFS,
		syscall.EAGAIN,
		syscall.EINTR,
	}

	for _, errno := range icmpDerived {
		if !transientErr(errno) {
			t.Errorf("%v (%d) treated as fatal; the tunnel would stop receiving", errno, int(errno))
		}
		if fatalErr(errno) {
			t.Errorf("%v classified as fatal", errno)
		}
	}
}

// The error rarely arrives bare: it comes back wrapped by our own code or by
// the net package, so the classifier has to unwrap.
func TestErrorClassificationUnwraps(t *testing.T) {
	wrapped := fmt.Errorf("transport read: %w", syscall.ENOPROTOOPT)
	if !transientErr(wrapped) {
		t.Error("fmt-wrapped ENOPROTOOPT not recognised")
	}

	opErr := &net.OpError{
		Op:  "read",
		Net: "udp",
		Err: &os.SyscallError{Syscall: "recvfrom", Err: syscall.ECONNREFUSED},
	}
	if !transientErr(opErr) {
		t.Error("net.OpError-wrapped ECONNREFUSED not recognised")
	}
}

func TestShutdownErrorsAreFatal(t *testing.T) {
	// Closing the fd is how shutdown looks from inside a blocking read; that
	// must stop the loop rather than spin on it.
	for _, err := range []error{syscall.EBADF, syscall.ENOTSOCK, net.ErrClosed} {
		if !fatalErr(err) {
			t.Errorf("%v should end the loop", err)
		}
		if transientErr(err) {
			t.Errorf("%v should not be retried forever", err)
		}
	}

	// Something genuinely unexpected is neither: it trips the fatal path and
	// exits for the supervisor to restart.
	if transientErr(syscall.EINVAL) || fatalErr(syscall.EINVAL) {
		t.Error("EINVAL should fall through to the unrecoverable path")
	}
	if transientErr(nil) {
		t.Error("nil is not an error")
	}
	if transientErr(errors.New("plain")) {
		t.Error("a non-syscall error should not be retried blindly")
	}
}

// A deadline expiring is normal for the UDP profile's return path.
func TestTimeoutsAreTransient(t *testing.T) {
	if !transientErr(&net.OpError{Op: "read", Err: os.ErrDeadlineExceeded}) {
		t.Error("a read deadline should not be fatal")
	}
}
