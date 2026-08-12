//go:build linux

package main

import (
	"os"
	"strings"
)

// applyTuning nudges kernel networking limits. Everything here is best-effort:
// containers hide most of /proc/sys and that must not stop the tunnel.
func applyTuning(profile string, log *Logger) {
	common := map[string]string{
		"net/ipv4/ip_forward":                "1",
		"net/ipv4/tcp_mtu_probing":           "1",
		"net/core/default_qdisc":             "fq",
		"net/ipv4/tcp_congestion_control":    "bbr",
		"net/ipv4/tcp_fastopen":              "3",
		"net/ipv4/tcp_slow_start_after_idle": "0",
		"net/ipv4/tcp_fin_timeout":           "15",
		"net/ipv4/tcp_syncookies":            "1",
		"net/core/somaxconn":                 "65535",
	}

	var specific map[string]string
	switch profile {
	case "fast", "throughput":
		specific = map[string]string{
			"net/core/rmem_max":           "268435456",
			"net/core/wmem_max":           "268435456",
			"net/core/rmem_default":       "16777216",
			"net/core/wmem_default":       "16777216",
			"net/core/netdev_max_backlog": "250000",
			"net/ipv4/tcp_rmem":           "4096 262144 268435456",
			"net/ipv4/tcp_wmem":           "4096 262144 268435456",
			"net/ipv4/udp_rmem_min":       "8192",
			"net/ipv4/udp_wmem_min":       "8192",
		}
	case "latency":
		specific = map[string]string{
			"net/core/rmem_max":           "16777216",
			"net/core/wmem_max":           "16777216",
			"net/core/netdev_max_backlog": "16384",
			"net/core/default_qdisc":      "fq_codel",
			"net/ipv4/tcp_rmem":           "4096 87380 16777216",
			"net/ipv4/tcp_wmem":           "4096 65536 16777216",
			"net/ipv4/tcp_low_latency":    "1",
			"net/ipv4/tcp_autocorking":    "0",
		}
	case "resource", "low":
		specific = map[string]string{
			"net/core/rmem_max":           "4194304",
			"net/core/wmem_max":           "4194304",
			"net/core/netdev_max_backlog": "4096",
		}
	default: // balanced
		specific = map[string]string{
			"net/core/rmem_max":           "67108864",
			"net/core/wmem_max":           "67108864",
			"net/core/rmem_default":       "8388608",
			"net/core/wmem_default":       "8388608",
			"net/core/netdev_max_backlog": "65536",
			"net/ipv4/tcp_rmem":           "4096 131072 67108864",
			"net/ipv4/tcp_wmem":           "4096 131072 67108864",
		}
	}

	applied, failed := 0, 0
	for _, set := range []map[string]string{common, specific} {
		for k, v := range set {
			if writeSysctl(k, v) {
				applied++
			} else {
				failed++
				log.Tracef("sysctl %s: not writable", strings.ReplaceAll(k, "/", "."))
			}
		}
	}
	log.Infof("kernel tuning profile %q applied (%d settings, %d unavailable)", profile, applied, failed)

	if !bbrActive() {
		log.Warnf("BBR congestion control is not active; run 'modprobe tcp_bbr' for the best throughput over lossy paths")
	}
}

func writeSysctl(path, value string) bool {
	full := "/proc/sys/" + path
	cur, err := os.ReadFile(full)
	if err == nil && strings.TrimSpace(string(cur)) == value {
		return true
	}
	return os.WriteFile(full, []byte(value), 0644) == nil
}

func bbrActive() bool {
	b, err := os.ReadFile("/proc/sys/net/ipv4/tcp_congestion_control")
	if err != nil {
		return true // unknown, do not nag
	}
	return strings.TrimSpace(string(b)) == "bbr"
}
