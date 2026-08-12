package main

import (
	"fmt"
	"net"
	"runtime"
	"strings"
)

type Config struct {
	// [transport]
	HeartbeatInterval int
	HeartbeatTimeout  int

	// [tun]
	TunName    string
	LocalAddr  string // CIDR, e.g. 10.20.20.1/24
	RemoteAddr string // CIDR, e.g. 10.20.20.2/24
	HealthPort int
	MTU        int

	// [ipx]
	Mode      string // server | client
	Profile   string // bip | icmp | ipip | gre | udp
	ListenIP  string
	DstIP     string
	Interface string
	ICMPType  int
	ICMPCode  int
	IPProto   int // raw IP protocol number for bip
	UDPPort   int // for the udp profile

	// [security]
	EnableEncryption bool
	Algorithm        string
	PSK              string
	KDFIterations    int
	Padding          int // max random pad bytes per packet, 0 = off

	// [tuning]
	AutoTuning    bool
	TuningProfile string
	Workers       int
	ChannelSize   int
	SoSndBuf      int
	SoRcvBuf      int

	// [logging]
	LogLevel string

	// [ports]
	Forwarder string // backhaul | iptables | none
	Mapping   []string

	// derived
	localIP  net.IP
	peerIP   net.IP
	listenIP net.IP
	dstIP    net.IP
}

func LoadConfig(path string) (*Config, error) {
	t, err := parseTOML(path)
	if err != nil {
		return nil, err
	}

	c := &Config{}

	if c.HeartbeatInterval, err = t.int("transport", "heartbeat_interval", 10); err != nil {
		return nil, err
	}
	if c.HeartbeatTimeout, err = t.int("transport", "heartbeat_timeout", 25); err != nil {
		return nil, err
	}

	c.TunName = t.str("tun", "name", "ipx0")
	c.LocalAddr = t.str("tun", "local_addr", "")
	c.RemoteAddr = t.str("tun", "remote_addr", "")
	if c.HealthPort, err = t.int("tun", "health_port", 0); err != nil {
		return nil, err
	}
	if c.MTU, err = t.int("tun", "mtu", 1400); err != nil {
		return nil, err
	}

	c.Mode = strings.ToLower(t.str("ipx", "mode", "server"))
	c.Profile = strings.ToLower(t.str("ipx", "profile", "bip"))
	c.ListenIP = t.str("ipx", "listen_ip", "")
	c.DstIP = t.str("ipx", "dst_ip", "")
	c.Interface = t.str("ipx", "interface", "")
	if c.ICMPType, err = t.int("ipx", "icmp_type", 0); err != nil {
		return nil, err
	}
	if c.ICMPCode, err = t.int("ipx", "icmp_code", 0); err != nil {
		return nil, err
	}
	if c.IPProto, err = t.int("ipx", "ip_proto", 143); err != nil {
		return nil, err
	}
	if c.UDPPort, err = t.int("ipx", "port", 8443); err != nil {
		return nil, err
	}

	if c.EnableEncryption, err = t.bool_("security", "enable_encryption", true); err != nil {
		return nil, err
	}
	c.Algorithm = strings.ToLower(t.str("security", "algorithm", "aes-256-gcm"))
	c.PSK = t.str("security", "psk", "")
	if c.KDFIterations, err = t.int("security", "kdf_iterations", 100000); err != nil {
		return nil, err
	}
	if c.Padding, err = t.int("security", "padding", 0); err != nil {
		return nil, err
	}

	if c.AutoTuning, err = t.bool_("tuning", "auto_tuning", true); err != nil {
		return nil, err
	}
	c.TuningProfile = strings.ToLower(t.str("tuning", "tuning_profile", "balanced"))
	if c.Workers, err = t.int("tuning", "workers", 0); err != nil {
		return nil, err
	}
	if c.ChannelSize, err = t.int("tuning", "channel_size", 4096); err != nil {
		return nil, err
	}
	if c.SoSndBuf, err = t.int("tuning", "so_sndbuf", 0); err != nil {
		return nil, err
	}
	if c.SoRcvBuf, err = t.int("tuning", "so_rcvbuf", 0); err != nil {
		return nil, err
	}

	c.LogLevel = strings.ToLower(t.str("logging", "log_level", "info"))

	c.Forwarder = strings.ToLower(t.str("ports", "forwarder", "backhaul"))
	c.Mapping = t.list("ports", "mapping")
	if !t.hasSection("ports") {
		c.Forwarder = "none"
	}

	if err := c.validate(); err != nil {
		return nil, err
	}
	return c, nil
}

func (c *Config) validate() error {
	switch c.Mode {
	case "server", "client":
	default:
		return fmt.Errorf("[ipx] mode must be server or client, got %q", c.Mode)
	}

	switch c.Profile {
	case "bip", "icmp", "ipip", "gre", "udp":
	default:
		return fmt.Errorf("[ipx] profile must be one of bip, icmp, ipip, gre, udp; got %q", c.Profile)
	}

	if len(c.TunName) == 0 || len(c.TunName) > 15 {
		return fmt.Errorf("[tun] name %q must be 1-15 characters", c.TunName)
	}

	ip, ipnet, err := net.ParseCIDR(c.LocalAddr)
	if err != nil {
		return fmt.Errorf("[tun] local_addr %q: %v", c.LocalAddr, err)
	}
	c.localIP = ip.To4()
	if c.localIP == nil {
		return fmt.Errorf("[tun] local_addr must be IPv4")
	}

	pip, _, err := net.ParseCIDR(c.RemoteAddr)
	if err != nil {
		// tolerate a bare address for remote_addr
		pip = net.ParseIP(strings.TrimSpace(c.RemoteAddr))
		if pip == nil {
			return fmt.Errorf("[tun] remote_addr %q: not an address or CIDR", c.RemoteAddr)
		}
	}
	c.peerIP = pip.To4()
	if c.peerIP == nil {
		return fmt.Errorf("[tun] remote_addr must be IPv4")
	}
	if c.localIP.Equal(c.peerIP) {
		return fmt.Errorf("[tun] local_addr and remote_addr are the same address (%s)", c.localIP)
	}
	if !ipnet.Contains(c.peerIP) {
		return fmt.Errorf("[tun] remote_addr %s is not inside local_addr subnet %s", c.peerIP, ipnet)
	}

	if c.MTU < 576 || c.MTU > 9000 {
		return fmt.Errorf("[tun] mtu %d out of range 576-9000", c.MTU)
	}

	if c.Profile != "udp" || c.ListenIP != "" {
		if c.listenIP = net.ParseIP(c.ListenIP).To4(); c.listenIP == nil {
			return fmt.Errorf("[ipx] listen_ip %q is not a valid IPv4 address", c.ListenIP)
		}
	}
	if c.DstIP != "" {
		if c.dstIP = net.ParseIP(c.DstIP).To4(); c.dstIP == nil {
			return fmt.Errorf("[ipx] dst_ip %q is not a valid IPv4 address", c.DstIP)
		}
	} else if c.Profile != "udp" || c.Mode == "client" {
		return fmt.Errorf("[ipx] dst_ip is required for profile %q in %s mode", c.Profile, c.Mode)
	}

	if c.Profile == "bip" && (c.IPProto < 1 || c.IPProto > 255 || c.IPProto == 1 || c.IPProto == 6 || c.IPProto == 17) {
		return fmt.Errorf("[ipx] ip_proto %d is invalid (must be 1-255 and not 1/6/17 which collide with ICMP/TCP/UDP)", c.IPProto)
	}
	if c.Profile == "icmp" {
		if c.ICMPType != 0 && c.ICMPType != 8 {
			return fmt.Errorf("[ipx] icmp_type must be 0 (echo reply) or 8 (echo request), got %d", c.ICMPType)
		}
	}

	if c.EnableEncryption {
		if c.PSK == "" {
			return fmt.Errorf("[security] psk is required when enable_encryption = true")
		}
		switch c.Algorithm {
		case "aes-256-gcm", "aes-128-gcm":
		case "chacha20-poly1305":
			return fmt.Errorf("[security] algorithm chacha20-poly1305 is not built in; use aes-256-gcm (hardware accelerated on any modern CPU)")
		default:
			return fmt.Errorf("[security] algorithm %q unsupported; use aes-256-gcm or aes-128-gcm", c.Algorithm)
		}
		if c.KDFIterations < 1000 {
			return fmt.Errorf("[security] kdf_iterations %d is too low, use at least 1000", c.KDFIterations)
		}
	}

	if c.Workers <= 0 {
		c.Workers = runtime.NumCPU()
	}
	if c.Workers > 32 {
		c.Workers = 32
	}
	if c.ChannelSize < 64 {
		c.ChannelSize = 64
	}
	if c.HeartbeatInterval < 1 {
		c.HeartbeatInterval = 10
	}
	if c.HeartbeatTimeout <= c.HeartbeatInterval {
		c.HeartbeatTimeout = c.HeartbeatInterval * 3
	}
	if c.Padding < 0 || c.Padding > 255 {
		return fmt.Errorf("[security] padding must be 0-255, got %d", c.Padding)
	}

	switch c.Forwarder {
	case "backhaul", "native", "iptables", "none", "":
	default:
		return fmt.Errorf("[ports] forwarder %q unsupported; use native, iptables or none", c.Forwarder)
	}

	// Overhead sanity: warn loudly rather than silently blackholing large packets.
	if over := c.encapOverhead() + c.MTU; over > 1500 {
		return fmt.Errorf("[tun] mtu %d plus %d bytes of %s encapsulation exceeds a 1500-byte path (total %d); lower the mtu",
			c.MTU, c.encapOverhead(), c.Profile, over)
	}

	return nil
}

// encapOverhead is everything we add on top of the inner IP packet.
func (c *Config) encapOverhead() int {
	outer := 20 // outer IPv4 header
	switch c.Profile {
	case "icmp":
		outer += 8
	case "gre":
		outer += 4
	case "udp":
		outer += 8
	}
	return outer + frameOverhead + c.Padding
}

// peerCIDRMask returns the prefix length configured on local_addr.
func (c *Config) prefixLen() int {
	_, ipnet, err := net.ParseCIDR(c.LocalAddr)
	if err != nil {
		return 24
	}
	ones, _ := ipnet.Mask.Size()
	return ones
}

func (c *Config) isServer() bool { return c.Mode == "server" }
