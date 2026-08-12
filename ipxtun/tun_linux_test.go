//go:build linux

package main

import (
	"sync"
	"testing"
)

// Regression test for the Ctrl+C panic: Close() cleared the queue slice while
// tx workers were still calling Read, and the queue index did i % len(fds)
// against a zero length.
func TestTunReadAfterCloseReturnsErrorNotPanic(t *testing.T) {
	// -1 is never a live descriptor, so nothing here touches real I/O.
	tun := &Tun{Name: "test0", MTU: 1320, fds: []int{-1, -1}}
	tun.Close()

	for _, worker := range []int{0, 1, 2, 7} {
		if _, err := tun.Read(worker, make([]byte, 64)); err == nil {
			t.Errorf("worker %d: read after close should fail", worker)
		} else if !fatalErr(err) {
			t.Errorf("worker %d: read returned %v, which would not stop the loop", worker, err)
		}
		if _, err := tun.Write(worker, []byte{0x45}); err == nil {
			t.Errorf("worker %d: write after close should fail", worker)
		}
	}
}

// A zero-value device must behave the same rather than dividing by zero.
func TestTunWithNoQueuesIsSafe(t *testing.T) {
	var tun Tun
	if _, err := tun.Read(0, make([]byte, 64)); !fatalErr(err) {
		t.Errorf("read on a device with no queues returned %v", err)
	}
	if _, err := tun.Write(0, []byte{0}); !fatalErr(err) {
		t.Errorf("write on a device with no queues returned %v", err)
	}
	tun.Close()
	tun.Close() // must be idempotent
}

// Close races every worker by construction, because closing the descriptors is
// what wakes them out of a blocking read.
func TestTunCloseRacesWorkers(t *testing.T) {
	tun := &Tun{Name: "test0", MTU: 1320, fds: []int{-1, -1, -1, -1}}

	var wg sync.WaitGroup
	stop := make(chan struct{})

	for w := 0; w < 8; w++ {
		wg.Add(1)
		go func(w int) {
			defer wg.Done()
			buf := make([]byte, 64)
			for {
				select {
				case <-stop:
					return
				default:
				}
				// Before the fix this panicked as soon as Close landed.
				_, _ = tun.Read(w, buf)
				_, _ = tun.Write(w, buf)
			}
		}(w)
	}

	for i := 0; i < 50; i++ {
		tun.Close()
	}
	close(stop)
	wg.Wait()
}
