//go:build linux

package main

import (
	"fmt"
	"net"
	"os/exec"
	"strconv"
	"strings"
)

// IPTables is the alternative forwarder: instead of proxying in userspace we
// let netfilter DNAT straight across the tunnel. It costs less CPU per byte but
// gives up per-connection accounting, so the native forwarder stays the default.
type IPTables struct {
	peer    net.IP
	tag     string
	applied [][]string
	log     *Logger
}

func NewIPTables(peer net.IP, tag string, log *Logger) *IPTables {
	return &IPTables{peer: peer, tag: tag, log: log}
}

func (t *IPTables) Apply(maps []PortMap) error {
	if _, err := exec.LookPath("iptables"); err != nil {
		return fmt.Errorf("forwarder = iptables but the iptables binary is missing: %v", err)
	}
	writeSysctl("net/ipv4/ip_forward", "1")

	// Clear anything we left behind after an unclean exit.
	t.Cleanup()

	for _, m := range maps {
		dest := net.JoinHostPort(t.peer.String(), strconv.Itoa(m.Target))
		for _, proto := range []string{"tcp", "udp"} {
			rule := []string{"-t", "nat", "PREROUTING", "-p", proto,
				"--dport", strconv.Itoa(m.Listen),
				"-m", "comment", "--comment", t.tag,
				"-j", "DNAT", "--to-destination", dest}
			if err := t.run("-A", rule); err != nil {
				t.Cleanup()
				return err
			}
			t.applied = append(t.applied, rule)
		}
	}

	masq := []string{"-t", "nat", "POSTROUTING", "-d", t.peer.String(),
		"-m", "comment", "--comment", t.tag, "-j", "MASQUERADE"}
	if err := t.run("-A", masq); err != nil {
		t.Cleanup()
		return err
	}
	t.applied = append(t.applied, masq)

	t.log.Infof("installed %d netfilter rules (tag %s)", len(t.applied), t.tag)
	return nil
}

func (t *IPTables) run(op string, rule []string) error {
	// rule is [-t table CHAIN ...]; the operation goes before the chain name.
	args := []string{rule[0], rule[1], op, rule[2]}
	args = append(args, rule[3:]...)
	out, err := exec.Command("iptables", args...).CombinedOutput()
	if err != nil {
		return fmt.Errorf("iptables %s: %v: %s", strings.Join(args, " "), err, strings.TrimSpace(string(out)))
	}
	return nil
}

// Cleanup removes every rule carrying our tag, including leftovers from a
// previous run that did not shut down cleanly.
func (t *IPTables) Cleanup() {
	for _, r := range t.applied {
		_ = t.run("-D", r)
	}
	t.applied = nil

	for _, chain := range []string{"PREROUTING", "POSTROUTING"} {
		for i := 0; i < 256; i++ {
			out, err := exec.Command("iptables", "-t", "nat", "-S", chain).Output()
			if err != nil {
				break
			}
			victim := ""
			for _, line := range strings.Split(string(out), "\n") {
				if strings.Contains(line, t.tag) {
					victim = line
					break
				}
			}
			if victim == "" {
				break
			}
			args := append([]string{"-t", "nat"}, splitRule(strings.Replace(victim, "-A", "-D", 1))...)
			if err := exec.Command("iptables", args...).Run(); err != nil {
				break
			}
		}
	}
}
