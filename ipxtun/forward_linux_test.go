//go:build linux

package main

import (
	"errors"
	"fmt"
	"net"
	"strings"
	"testing"
)

// A port conflict is the failure an operator is most likely to hit, so the
// message has to name the port and say what to do about it. This also pins down
// that errors.Is reaches the errno through whatever the net package wraps it in
// — which is platform specific, hence the linux tag.
func TestBindErrorIsRecognisedAndActionable(t *testing.T) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Skipf("cannot listen at all: %v", err)
	}
	defer ln.Close()
	port := ln.Addr().(*net.TCPAddr).Port

	_, err = net.Listen("tcp", fmt.Sprintf("127.0.0.1:%d", port))
	if err == nil {
		t.Fatal("second listen on the same port unexpectedly succeeded")
	}

	msg := bindError("tcp", port, err).Error()
	if !strings.Contains(msg, "already in use") {
		t.Errorf("EADDRINUSE not recognised through the net wrapper; got: %s", msg)
	}
	if !strings.Contains(msg, fmt.Sprint(port)) {
		t.Errorf("message does not name the port: %s", msg)
	}
	if !strings.Contains(msg, "ss -lntup") {
		t.Errorf("message does not say how to find the owner: %s", msg)
	}
	if !strings.Contains(msg, "systemctl") {
		t.Errorf("message does not warn that killing a supervised process is futile: %s", msg)
	}

	// An unrelated failure must not be mislabelled as a port conflict.
	other := bindError("tcp", 80, errors.New("some other problem")).Error()
	if strings.Contains(other, "already in use") {
		t.Errorf("unrelated error reported as a port conflict: %s", other)
	}
}
