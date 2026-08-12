//go:build linux

package main

import (
	"fmt"
	"os/exec"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"unsafe"
)

const (
	iffTun        = 0x0001
	iffNoPI       = 0x1000
	iffMultiQueue = 0x0100

	tunsetiff = 0x400454ca
)

type ifreq struct {
	name  [16]byte
	flags uint16
	_     [22]byte
}

// Tun is a (possibly multi-queue) TUN device. Each queue is an independent fd;
// the kernel hashes flows across them, so N queues give N genuinely parallel
// datapaths with no locking on our side.
type Tun struct {
	Name string
	MTU  int
	fds  []int

	// Shutdown has to close the descriptors to wake workers blocked in read(),
	// so those workers necessarily race with Close. The flag lets them find out
	// before touching the slice.
	closed atomic.Bool
	once   sync.Once
}

func OpenTun(name string, mtu, queues int) (*Tun, error) {
	if queues < 1 {
		queues = 1
	}
	t := &Tun{Name: name, MTU: mtu}

	multi := queues > 1
	for i := 0; i < queues; i++ {
		fd, err := openTunQueue(name, multi)
		if err != nil {
			if i > 0 && multi {
				// Kernel without multi-queue support: fall back to a single queue.
				t.Close()
				return OpenTun(name, mtu, 1)
			}
			t.Close()
			return nil, err
		}
		t.fds = append(t.fds, fd)
	}
	return t, nil
}

func openTunQueue(name string, multiqueue bool) (int, error) {
	fd, err := syscall.Open("/dev/net/tun", syscall.O_RDWR|syscall.O_CLOEXEC, 0)
	if err != nil {
		return -1, fmt.Errorf("open /dev/net/tun: %v (is the tun module loaded? try: modprobe tun)", err)
	}

	var req ifreq
	copy(req.name[:15], name)
	req.flags = iffTun | iffNoPI
	if multiqueue {
		req.flags |= iffMultiQueue
	}

	if _, _, errno := syscall.Syscall(syscall.SYS_IOCTL, uintptr(fd), tunsetiff,
		uintptr(unsafe.Pointer(&req))); errno != 0 {
		syscall.Close(fd)
		return -1, fmt.Errorf("TUNSETIFF %s: %v", name, errno)
	}
	return fd, nil
}

func (t *Tun) Queues() int { return len(t.fds) }

// fd picks the queue for a worker. Once the device is closed it reports EBADF
// rather than indexing, which is what a worker would have seen from the kernel
// a moment later anyway, and which its loop already treats as "stop".
func (t *Tun) fd(i int) (int, error) {
	if t.closed.Load() || len(t.fds) == 0 {
		return -1, syscall.EBADF
	}
	return t.fds[i%len(t.fds)], nil
}

func (t *Tun) Read(i int, b []byte) (int, error) {
	fd, err := t.fd(i)
	if err != nil {
		return 0, err
	}
	return syscall.Read(fd, b)
}

func (t *Tun) Write(i int, b []byte) (int, error) {
	fd, err := t.fd(i)
	if err != nil {
		return 0, err
	}
	return syscall.Write(fd, b)
}

func (t *Tun) Close() error {
	t.once.Do(func() {
		t.closed.Store(true)
		for _, fd := range t.fds {
			syscall.Close(fd)
		}
	})
	return nil
}

// Configure brings the interface up with its address and MTU. Shelling out to
// `ip` keeps us free of a netlink dependency and matches what every distro ships.
func (t *Tun) Configure(localCIDR string, mtu int, txqueuelen int) error {
	steps := [][]string{
		{"link", "set", "dev", t.Name, "mtu", strconv.Itoa(mtu)},
		{"link", "set", "dev", t.Name, "txqueuelen", strconv.Itoa(txqueuelen)},
		{"addr", "replace", localCIDR, "dev", t.Name},
		{"link", "set", "dev", t.Name, "up"},
	}
	for _, args := range steps {
		if out, err := runIP(args...); err != nil {
			return fmt.Errorf("ip %s: %v: %s", strings.Join(args, " "), err, out)
		}
	}
	return nil
}

func runIP(args ...string) (string, error) {
	cmd := exec.Command("ip", args...)
	out, err := cmd.CombinedOutput()
	return strings.TrimSpace(string(out)), err
}

// hostIPForInterface returns the primary IPv4 of an interface, used to sanity
// check listen_ip against reality.
func hostIPForInterface(name string) string {
	out, err := runIP("-4", "-o", "addr", "show", "dev", name)
	if err != nil {
		return ""
	}
	fields := strings.Fields(out)
	for i, f := range fields {
		if f == "inet" && i+1 < len(fields) {
			return strings.Split(fields[i+1], "/")[0]
		}
	}
	return ""
}

func defaultRouteInterface() string {
	out, err := runIP("route", "show", "default")
	if err != nil {
		return ""
	}
	fields := strings.Fields(out)
	for i, f := range fields {
		if f == "dev" && i+1 < len(fields) {
			return fields[i+1]
		}
	}
	return ""
}
