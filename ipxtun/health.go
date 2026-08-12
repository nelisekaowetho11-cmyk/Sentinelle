package main

import (
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"strconv"
	"time"
)

// HealthServer exposes liveness and counters. It binds on the tunnel address
// and loopback only, never on the public interface.
type HealthServer struct {
	srv  *http.Server
	ln   net.Listener
	st   *Stats
	cfg  *Config
	log  *Logger
	desc string
}

func NewHealthServer(cfg *Config, st *Stats, log *Logger, desc string) (*HealthServer, error) {
	if cfg.HealthPort <= 0 {
		return nil, nil
	}

	h := &HealthServer{st: st, cfg: cfg, log: log, desc: desc}
	mux := http.NewServeMux()
	mux.HandleFunc("/", h.handleHealth)
	mux.HandleFunc("/health", h.handleHealth)
	mux.HandleFunc("/stats", h.handleStats)
	mux.HandleFunc("/metrics", h.handleMetrics)

	addr := net.JoinHostPort(cfg.localIP.String(), strconv.Itoa(cfg.HealthPort))
	ln, err := net.Listen("tcp", addr)
	if err != nil {
		return nil, fmt.Errorf("health listen %s: %v", addr, err)
	}
	h.ln = ln
	h.srv = &http.Server{
		Handler:           mux,
		ReadHeaderTimeout: 5 * time.Second,
	}
	return h, nil
}

func (h *HealthServer) Start() {
	if h == nil {
		return
	}
	go func() {
		if err := h.srv.Serve(h.ln); err != nil && err != http.ErrServerClosed {
			h.log.Warnf("health server stopped: %v", err)
		}
	}()
	h.log.Infof("health endpoint on http://%s", h.ln.Addr())
}

func (h *HealthServer) Close() {
	if h == nil {
		return
	}
	h.srv.Close()
}

func (h *HealthServer) handleHealth(w http.ResponseWriter, r *http.Request) {
	up := h.st.PeerUp.Load()
	code := http.StatusOK
	if !up {
		code = http.StatusServiceUnavailable
	}
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	json.NewEncoder(w).Encode(map[string]any{
		"status":  map[bool]string{true: "up", false: "down"}[up],
		"peer":    h.cfg.peerIP.String(),
		"uptime":  int64(h.st.Uptime().Seconds()),
		"rtt_ms":  float64(h.st.PeerRTTMicro.Load()) / 1000.0,
		"profile": h.cfg.Profile,
	})
}

func (h *HealthServer) handleStats(w http.ResponseWriter, r *http.Request) {
	s := h.st
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]any{
		"transport":    h.desc,
		"mode":         h.cfg.Mode,
		"profile":      h.cfg.Profile,
		"interface":    h.cfg.TunName,
		"mtu":          h.cfg.MTU,
		"uptime_s":     int64(s.Uptime().Seconds()),
		"peer_up":      s.PeerUp.Load(),
		"peer_rtt_ms":  float64(s.PeerRTTMicro.Load()) / 1000.0,
		"peer_flaps":   s.PeerFlaps.Load(),
		"last_rx_ago":  time.Since(time.Unix(s.LastRxUnix.Load(), 0)).Seconds(),
		"tx_packets":   s.TxPackets.Load(),
		"tx_bytes":     s.TxBytes.Load(),
		"tx_errors":    s.TxErrors.Load(),
		"rx_packets":   s.RxPackets.Load(),
		"rx_bytes":     s.RxBytes.Load(),
		"rx_errors":    s.RxErrors.Load(),
		"auth_failed":  s.AuthFailed.Load(),
		"replay_drops": s.ReplayDrops.Load(),
		"tun_drops":    s.TunDrops.Load(),
		"pool_stalls":  s.PoolStalls.Load(),
		"oversize":     s.Oversize.Load(),
		"tcp_open":     s.TCPOpen.Load(),
		"tcp_active":   s.TCPActive.Load(),
		"tcp_failed":   s.TCPFailed.Load(),
		"udp_active":   s.UDPActive.Load(),
		"udp_failed":   s.UDPFailed.Load(),
		"fwd_up":       s.FwdBytesUp.Load(),
		"fwd_down":     s.FwdBytesDown.Load(),
	})
}

func (h *HealthServer) handleMetrics(w http.ResponseWriter, r *http.Request) {
	s := h.st
	w.Header().Set("Content-Type", "text/plain; version=0.0.4")
	up := 0
	if s.PeerUp.Load() {
		up = 1
	}
	fmt.Fprintf(w, "# HELP ipxtun_peer_up Peer reachability (1 = heartbeats arriving)\n")
	fmt.Fprintf(w, "# TYPE ipxtun_peer_up gauge\nipxtun_peer_up %d\n", up)
	fmt.Fprintf(w, "# TYPE ipxtun_rtt_seconds gauge\nipxtun_rtt_seconds %f\n",
		float64(s.PeerRTTMicro.Load())/1e6)
	for name, v := range map[string]uint64{
		"ipxtun_tx_packets_total":   s.TxPackets.Load(),
		"ipxtun_tx_bytes_total":     s.TxBytes.Load(),
		"ipxtun_tx_errors_total":    s.TxErrors.Load(),
		"ipxtun_rx_packets_total":   s.RxPackets.Load(),
		"ipxtun_rx_bytes_total":     s.RxBytes.Load(),
		"ipxtun_rx_errors_total":    s.RxErrors.Load(),
		"ipxtun_auth_failed_total":  s.AuthFailed.Load(),
		"ipxtun_replay_drops_total": s.ReplayDrops.Load(),
		"ipxtun_tun_drops_total":    s.TunDrops.Load(),
		"ipxtun_tcp_open_total":     s.TCPOpen.Load(),
	} {
		fmt.Fprintf(w, "# TYPE %s counter\n%s %d\n", name, name, v)
	}
	fmt.Fprintf(w, "# TYPE ipxtun_tcp_active gauge\nipxtun_tcp_active %d\n", s.TCPActive.Load())
	fmt.Fprintf(w, "# TYPE ipxtun_udp_active gauge\nipxtun_udp_active %d\n", s.UDPActive.Load())
}
