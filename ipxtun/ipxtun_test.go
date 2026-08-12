package main

import (
	"bytes"
	"encoding/hex"
	"math/rand"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
)

// The exact shape of the original tool's config, so we can prove the parser
// accepts existing files unchanged.
const legacyConfig = `[transport]
type = "tun"
heartbeat_interval = 10
heartbeat_timeout = 25

[tun]
encapsulation = "ipx"
name = "backhaul-bip"
local_addr = "10.20.20.1/24"
remote_addr = "10.20.20.2/24"
health_port = 1235
mtu = 1320

[ipx]
mode = "server"
profile = "bip"
listen_ip = "203.0.113.10"
dst_ip = "198.51.100.10"
interface = "eth0"

[security]
enable_encryption = true
algorithm = "aes-256-gcm"
psk = "pN9m6m0tH3nE3V8xKZ6Lq5yYcW2K1S7QG9u4cF0A8M4="
kdf_iterations = 100000

[tuning]
auto_tuning = true
tuning_profile = "balanced"
workers = 0
channel_size = 10_000
batch_size = 2048
so_sndbuf = 0

[logging]
log_level = "info"

[ports]
forwarder = "backhaul"
mapping = [
    "8080=8081",
    "8040=8041",
    "8020=8021",
    "5001=5000",
]
`

func writeTemp(t *testing.T, body string) string {
	t.Helper()
	p := filepath.Join(t.TempDir(), "cfg.toml")
	if err := os.WriteFile(p, []byte(body), 0600); err != nil {
		t.Fatal(err)
	}
	return p
}

func TestLegacyConfigLoadsUnchanged(t *testing.T) {
	cfg, err := LoadConfig(writeTemp(t, legacyConfig))
	if err != nil {
		t.Fatalf("legacy config rejected: %v", err)
	}

	if cfg.Mode != "server" || cfg.Profile != "bip" {
		t.Errorf("mode/profile = %s/%s, want server/bip", cfg.Mode, cfg.Profile)
	}
	if cfg.MTU != 1320 || cfg.HealthPort != 1235 {
		t.Errorf("mtu/health = %d/%d, want 1320/1235", cfg.MTU, cfg.HealthPort)
	}
	if cfg.ChannelSize != 10000 {
		t.Errorf("channel_size = %d, want 10000 (underscore separator)", cfg.ChannelSize)
	}
	if cfg.localIP.String() != "10.20.20.1" || cfg.peerIP.String() != "10.20.20.2" {
		t.Errorf("addresses = %s/%s", cfg.localIP, cfg.peerIP)
	}
	if cfg.Workers <= 0 {
		t.Errorf("workers should default to CPU count, got %d", cfg.Workers)
	}
	if len(cfg.Mapping) != 4 {
		t.Fatalf("mapping = %v, want 4 entries", cfg.Mapping)
	}
	if cfg.Mapping[0] != "8080=8081" {
		t.Errorf("mapping[0] = %q", cfg.Mapping[0])
	}
}

func TestConfigRejectsBadInput(t *testing.T) {
	cases := map[string]string{
		"peer outside subnet": `[tun]
local_addr = "10.20.20.1/24"
remote_addr = "10.99.99.2/24"
[ipx]
mode = "server"
profile = "bip"
listen_ip = "1.2.3.4"
dst_ip = "5.6.7.8"
[security]
psk = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaA="`,

		"identical endpoints": `[tun]
local_addr = "10.20.20.1/24"
remote_addr = "10.20.20.1/24"
[ipx]
mode = "server"
profile = "bip"
listen_ip = "1.2.3.4"
dst_ip = "5.6.7.8"
[security]
psk = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaA="`,

		"missing psk": `[tun]
local_addr = "10.20.20.1/24"
remote_addr = "10.20.20.2/24"
[ipx]
mode = "server"
profile = "bip"
listen_ip = "1.2.3.4"
dst_ip = "5.6.7.8"
[security]
enable_encryption = true`,

		"mtu too large for path": `[tun]
local_addr = "10.20.20.1/24"
remote_addr = "10.20.20.2/24"
mtu = 1500
[ipx]
mode = "server"
profile = "icmp"
listen_ip = "1.2.3.4"
dst_ip = "5.6.7.8"
[security]
psk = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaA="`,

		"unknown profile": `[tun]
local_addr = "10.20.20.1/24"
remote_addr = "10.20.20.2/24"
[ipx]
mode = "server"
profile = "carrier-pigeon"
listen_ip = "1.2.3.4"
dst_ip = "5.6.7.8"
[security]
psk = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaA="`,
	}

	for name, body := range cases {
		t.Run(name, func(t *testing.T) {
			if _, err := LoadConfig(writeTemp(t, body)); err == nil {
				t.Fatal("expected a config error, got none")
			}
		})
	}
}

// Every config we ship must load, and the two ends of each tunnel must agree
// on the settings that have to match or the link silently fails.
func TestShippedConfigsAreValid(t *testing.T) {
	files, err := filepath.Glob(filepath.Join("configs", "*.toml"))
	if err != nil || len(files) == 0 {
		t.Skipf("no example configs found (%v)", err)
	}

	loaded := map[string]*Config{}
	for _, f := range files {
		cfg, err := LoadConfig(f)
		if err != nil {
			t.Errorf("%s: %v", filepath.Base(f), err)
			continue
		}
		loaded[filepath.Base(f)] = cfg
	}

	pairs := [][2]string{
		{"iran_bip.toml", "kharej_bip.toml"},
		{"iran_icmp.toml", "kharej_icmp.toml"},
		{"iran2_bip.toml", "kharej2_bip.toml"},
	}
	for _, p := range pairs {
		a, b := loaded[p[0]], loaded[p[1]]
		if a == nil || b == nil {
			continue
		}
		name := p[0] + "/" + p[1]

		if a.PSK != b.PSK {
			t.Errorf("%s: PSK differs; the tunnel would never authenticate", name)
		}
		if a.MTU != b.MTU {
			t.Errorf("%s: mtu differs (%d vs %d)", name, a.MTU, b.MTU)
		}
		if a.Profile != b.Profile || a.IPProto != b.IPProto {
			t.Errorf("%s: profile/ip_proto differ", name)
		}
		if a.Algorithm != b.Algorithm || a.KDFIterations != b.KDFIterations {
			t.Errorf("%s: cipher or KDF settings differ, keys would not match", name)
		}
		if a.Mode != "server" || b.Mode != "client" {
			t.Errorf("%s: expected one server and one client, got %s/%s", name, a.Mode, b.Mode)
		}
		// The endpoints must be mirror images of each other.
		if a.ListenIP != b.DstIP || b.ListenIP != a.DstIP {
			t.Errorf("%s: endpoints are not mirrored (%s->%s vs %s->%s)",
				name, a.ListenIP, a.DstIP, b.ListenIP, b.DstIP)
		}
		if !a.localIP.Equal(b.peerIP) || !b.localIP.Equal(a.peerIP) {
			t.Errorf("%s: tunnel addresses are not mirrored", name)
		}
	}

	// Distinct tunnels must not collide on the wire or in the kernel.
	seenHealth := map[int]string{}
	seenName := map[string]string{}
	for file, cfg := range loaded {
		if prev, ok := seenName[cfg.TunName]; ok && !sameTunnel(file, prev) {
			t.Errorf("%s and %s both use interface %s", file, prev, cfg.TunName)
		}
		seenName[cfg.TunName] = file
		if prev, ok := seenHealth[cfg.HealthPort]; ok && !sameTunnel(file, prev) {
			t.Errorf("%s and %s both use health_port %d", file, prev, cfg.HealthPort)
		}
		seenHealth[cfg.HealthPort] = file
	}

	// The default PSK baked into the original installer must never reappear.
	const leaked = "pN9m6m0tH3nE3V8xKZ6Lq5yYcW2K1S7QG9u4cF0A8M4="
	for file, cfg := range loaded {
		if cfg.PSK == leaked {
			t.Errorf("%s still uses the installer's default PSK", file)
		}
	}
}

// Coexistence with backhaul matters only while both are running, which is a
// migration phase, not a property of the software. Once you cut over, taking
// backhaul's ports is the whole point — so this is opt-in:
//
//	IPXTUN_CHECK_COEXIST=1 go test -run Coexist
//
// Run it while you are still testing side by side. After cutover, ignore it:
// the real protection then is the bind itself, which fails loudly if something
// else already holds the port.
func TestShippedConfigsCoexistWithBackhaul(t *testing.T) {
	if os.Getenv("IPXTUN_CHECK_COEXIST") == "" {
		t.Skip("set IPXTUN_CHECK_COEXIST=1 while migrating, when both tunnels run at once")
	}

	// Values taken from the original backhaul_p configs.
	legacySubnets := []string{"10.20.20.", "10.10.10.", "10.20.21."}
	legacyHealth := map[int]bool{1234: true, 1235: true, 1236: true}
	legacyPorts := map[int]bool{8080: true, 8040: true, 8020: true, 5001: true}

	files, err := filepath.Glob(filepath.Join("configs", "*.toml"))
	if err != nil || len(files) == 0 {
		t.Skipf("no example configs found (%v)", err)
	}

	for _, f := range files {
		name := filepath.Base(f)
		cfg, err := LoadConfig(f)
		if err != nil {
			t.Errorf("%s: %v", name, err)
			continue
		}

		for _, s := range legacySubnets {
			if strings.HasPrefix(cfg.LocalAddr, s) {
				t.Errorf("%s: local_addr %s is backhaul's subnet %sx; fine after cutover, "+
					"but it will clash while both run", name, cfg.LocalAddr, s)
			}
		}
		if legacyHealth[cfg.HealthPort] {
			t.Errorf("%s: health_port %d is backhaul's; fine after cutover, "+
				"but the bind will fail while both run", name, cfg.HealthPort)
		}
		if strings.HasPrefix(cfg.TunName, "backhaul") {
			t.Errorf("%s: interface name %q is backhaul's device", name, cfg.TunName)
		}

		maps, err := parseMappings(cfg.Mapping)
		if err != nil {
			t.Errorf("%s: %v", name, err)
			continue
		}
		for _, m := range maps {
			if legacyPorts[m.Listen] {
				t.Errorf("%s: forwards public port %d, which backhaul also uses; "+
					"expected after cutover, a conflict before it", name, m.Listen)
			}
		}
	}
}

// sameTunnel reports whether two config filenames are the two ends of one
// tunnel, which are expected to share an interface name and health port.
func sameTunnel(a, b string) bool {
	strip := func(s string) string {
		s = strings.TrimSuffix(s, ".toml")
		s = strings.TrimPrefix(s, "iran")
		s = strings.TrimPrefix(s, "kharej")
		return s
	}
	return strip(a) == strip(b)
}

func testCrypto(t *testing.T, psk string) *Crypto {
	t.Helper()
	// Low iteration count keeps the tests fast; the KDF itself is covered
	// separately against published vectors.
	c, err := NewCrypto(&Config{
		EnableEncryption: true,
		Algorithm:        "aes-256-gcm",
		PSK:              psk,
		KDFIterations:    1000,
	})
	if err != nil {
		t.Fatal(err)
	}
	return c
}

func TestCodecRoundTrip(t *testing.T) {
	c := testCrypto(t, "pN9m6m0tH3nE3V8xKZ6Lq5yYcW2K1S7QG9u4cF0A8M4=")

	for _, pad := range []int{0, 64, 255} {
		enc := newCodec(c, 0xDEADBEEF, 0, pad, 1500)
		dec := newCodec(c, 0x11111111, 1, 0, 1500)

		for _, size := range []int{1, 20, 576, 1320, 1500} {
			payload := make([]byte, size)
			rand.Read(payload)

			out := make([]byte, size+frameOverhead+pad+128)
			frame, err := enc.Seal(out, ptData, payload)
			if err != nil {
				t.Fatalf("seal(pad=%d,size=%d): %v", pad, size, err)
			}
			if len(frame) < size+frameOverhead {
				t.Fatalf("frame too short: %d for payload %d", len(frame), size)
			}

			plainBuf := make([]byte, 4096)
			typ, sess, ctr, got, err := dec.Open(plainBuf, frame)
			if err != nil {
				t.Fatalf("open(pad=%d,size=%d): %v", pad, size, err)
			}
			if typ != ptData {
				t.Errorf("type = %d, want %d", typ, ptData)
			}
			if sess != 0xDEADBEEF {
				t.Errorf("session = %08x, want deadbeef", sess)
			}
			if ctr == 0 {
				t.Error("counter should never be zero")
			}
			if !bytes.Equal(got, payload) {
				t.Errorf("payload round trip mismatch at size %d (got %d bytes)", size, len(got))
			}
		}
	}
}

func TestCodecRejectsTampering(t *testing.T) {
	c := testCrypto(t, "pN9m6m0tH3nE3V8xKZ6Lq5yYcW2K1S7QG9u4cF0A8M4=")
	enc := newCodec(c, 0xABCD1234, 0, 0, 1500)
	dec := newCodec(c, 1, 1, 0, 1500)

	payload := []byte("the quick brown fox jumps over the lazy dog")
	out := make([]byte, 512)
	frame, _ := enc.Seal(out, ptData, payload)

	// Every single-bit flip anywhere in the frame must be rejected: the header
	// is an AEAD associated-data input, so it is as protected as the body.
	for i := 0; i < len(frame); i++ {
		bad := make([]byte, len(frame))
		copy(bad, frame)
		bad[i] ^= 0x40

		plainBuf := make([]byte, 512)
		if _, _, _, _, err := dec.Open(plainBuf, bad); err == nil {
			t.Fatalf("tampered byte %d of %d was accepted", i, len(frame))
		}
	}
}

func TestCodecRejectsForeignKey(t *testing.T) {
	mine := testCrypto(t, "pN9m6m0tH3nE3V8xKZ6Lq5yYcW2K1S7QG9u4cF0A8M4=")
	theirs := testCrypto(t, "9/elXToUTGfiheE+sYif+j0BH1RuRzlUHhkyzXVb/4A=")

	enc := newCodec(theirs, 7, 0, 0, 1500)
	dec := newCodec(mine, 8, 0, 0, 1500)

	out := make([]byte, 512)
	frame, _ := enc.Seal(out, ptData, []byte("hello from the wrong tunnel"))

	plainBuf := make([]byte, 512)
	if _, _, _, _, err := dec.Open(plainBuf, frame); err == nil {
		t.Fatal("a frame sealed with a different PSK was accepted")
	}
}

func TestHeaderLooksRandomOnTheWire(t *testing.T) {
	c := testCrypto(t, "pN9m6m0tH3nE3V8xKZ6Lq5yYcW2K1S7QG9u4cF0A8M4=")
	enc := newCodec(c, 0x01020304, 0, 0, 1500)

	out := make([]byte, 512)
	frame, _ := enc.Seal(out, ptData, []byte("payload"))

	// A plaintext header would start with the version byte and a zero type.
	// If either shows through, the format is fingerprintable by a DPI box.
	if frame[0] == protoVersion && frame[1] == ptData {
		t.Fatal("header is going out in the clear; it must be obfuscated")
	}

	// Two frames from the same session must not share a header prefix either,
	// or a filter could key on the repeating bytes.
	frame2, _ := enc.Seal(make([]byte, 512), ptData, []byte("payload"))
	if bytes.Equal(frame[:hdrLen], frame2[:hdrLen]) {
		t.Fatal("consecutive headers are identical on the wire")
	}
}

func TestReplayWindow(t *testing.T) {
	w := newReplayWindow()

	if !w.accept(100) {
		t.Fatal("first packet rejected")
	}
	if w.accept(100) {
		t.Fatal("exact duplicate accepted")
	}
	if !w.accept(101) {
		t.Fatal("next in sequence rejected")
	}

	// Out of order but inside the window is legitimate on any real network.
	if !w.accept(99) {
		t.Fatal("in-window reorder rejected")
	}
	if w.accept(99) {
		t.Fatal("duplicate of a reordered packet accepted")
	}

	// A big forward jump must not wedge the window.
	if !w.accept(100000) {
		t.Fatal("large forward jump rejected")
	}
	if w.accept(100000) {
		t.Fatal("duplicate after jump accepted")
	}
	if w.accept(50) {
		t.Fatal("ancient packet accepted after the window moved on")
	}

	// Each sender worker owns the high byte, so shards must stay independent.
	const worker3 = uint64(3) << 56
	if !w.accept(worker3 + 1) {
		t.Fatal("first packet from another worker shard rejected")
	}
	if w.accept(worker3 + 1) {
		t.Fatal("duplicate within a worker shard accepted")
	}
}

func TestReplayWindowConcurrent(t *testing.T) {
	w := newReplayWindow()
	const workers, perWorker = 8, 2000

	var wg sync.WaitGroup
	accepted := make([]int, workers)
	for id := 0; id < workers; id++ {
		wg.Add(1)
		go func(id int) {
			defer wg.Done()
			base := uint64(id) << 56
			n := 0
			for i := uint64(1); i <= perWorker; i++ {
				if w.accept(base + i) {
					n++
				}
			}
			accepted[id] = n
		}(id)
	}
	wg.Wait()

	for id, n := range accepted {
		if n != perWorker {
			t.Errorf("worker %d: accepted %d of %d fresh counters", id, n, perWorker)
		}
	}
}

func TestPBKDF2AgainstPublishedVectors(t *testing.T) {
	cases := []struct {
		pass, salt string
		iter, size int
		want       string
	}{
		{"password", "salt", 1, 32, "120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b"},
		{"password", "salt", 2, 32, "ae4d0c95af6b46d32d0adff928f06dd02a303f8ef3c251dfd6e2d85a95474c43"},
		{"password", "salt", 4096, 32, "c5e478d59288c841aa530db6845c4c8d962893a001ce4e11a4963873aa98134a"},
	}
	for _, c := range cases {
		got := hex.EncodeToString(pbkdf2SHA256([]byte(c.pass), []byte(c.salt), c.iter, c.size))
		if got != c.want {
			t.Errorf("pbkdf2(%q,%q,%d)\n got %s\nwant %s", c.pass, c.salt, c.iter, got, c.want)
		}
	}
}

func TestKeySeparation(t *testing.T) {
	const psk = "pN9m6m0tH3nE3V8xKZ6Lq5yYcW2K1S7QG9u4cF0A8M4="
	data := deriveKey(psk, 1000, "data", 32)
	hdr := deriveKey(psk, 1000, "header", 32)
	id := deriveKey(psk, 1000, "icmp-id", 32)

	if bytes.Equal(data, hdr) || bytes.Equal(data, id) || bytes.Equal(hdr, id) {
		t.Fatal("derived keys collide; the label is not being mixed in")
	}
}

func TestParseMappings(t *testing.T) {
	got, err := parseMappings([]string{"8080=8081", "5001=5000", "443", "9000-9002", "7000-7001:5201"})
	if err != nil {
		t.Fatal(err)
	}
	want := []PortMap{
		{8080, 8081}, {5001, 5000}, {443, 443},
		{9000, 9000}, {9001, 9001}, {9002, 9002},
		{7000, 5201}, {7001, 5201},
	}
	if len(got) != len(want) {
		t.Fatalf("got %d mappings, want %d: %+v", len(got), len(want), got)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("mapping %d = %+v, want %+v", i, got[i], want[i])
		}
	}

	if _, err := parseMappings([]string{"8080=8081", "8080=9999"}); err == nil {
		t.Error("duplicate listen port should be rejected before we fail at bind time")
	}
	if _, err := parseMappings([]string{"not-a-port"}); err == nil {
		t.Error("garbage mapping accepted")
	}
	if _, err := parseMappings([]string{"70000"}); err == nil {
		t.Error("out-of-range port accepted")
	}
}

func TestChecksum(t *testing.T) {
	// Echo reply, id 1, seq 8, checksum field zeroed: the words sum to 9, so
	// the one's complement is 0xfff6.
	pkt := []byte{0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x08}
	if got := checksum(pkt); got != 0xfff6 {
		t.Errorf("checksum = %#04x, want 0xfff6", got)
	}

	// The textbook IPv4 header example (20 bytes, checksum field zeroed,
	// 192.168.0.1 -> 192.168.0.199) checksums to 0xb861.
	hdr, err := hex.DecodeString("450000730000400040110000c0a80001c0a800c7")
	if err != nil {
		t.Fatal(err)
	}
	if got := checksum(hdr); got != 0xb861 {
		t.Errorf("IPv4 header checksum = %#04x, want 0xb861", got)
	}
	// With the checksum written back in, the header must verify to zero.
	hdr[10], hdr[11] = 0xb8, 0x61
	if got := checksum(hdr); got != 0 {
		t.Errorf("header with checksum installed = %#04x, want 0", got)
	}

	// Odd-length input must be padded on the right, not dropped.
	if checksum([]byte{0x01}) == checksum([]byte{0x00, 0x01}) {
		t.Error("odd trailing byte is being treated as a low byte instead of a high byte")
	}

	// A packet carrying its own correct checksum must verify to zero.
	full := make([]byte, len(pkt))
	copy(full, pkt)
	sum := checksum(full)
	full[2] = byte(sum >> 8)
	full[3] = byte(sum)
	if got := checksum(full); got != 0 {
		t.Errorf("verification checksum = %#04x, want 0", got)
	}
}

func TestTOMLQuirks(t *testing.T) {
	body := `# leading comment
[a]
str = "value # not a comment"
num = 1_000_000
yes = true
[b]
list = [
    "one",   # trailing comment
    "two",
]
empty_section_key = "x"
`
	p := writeTemp(t, body)
	tf, err := parseTOML(p)
	if err != nil {
		t.Fatal(err)
	}
	if got := tf.str("a", "str", ""); got != "value # not a comment" {
		t.Errorf("a.str = %q; # inside quotes must not start a comment", got)
	}
	n, err := tf.int("a", "num", 0)
	if err != nil || n != 1000000 {
		t.Errorf("a.num = %d (%v), want 1000000", n, err)
	}
	b, err := tf.bool_("a", "yes", false)
	if err != nil || !b {
		t.Errorf("a.yes = %v (%v)", b, err)
	}
	if l := tf.list("b", "list"); len(l) != 2 || l[0] != "one" || l[1] != "two" {
		t.Errorf("b.list = %v, want [one two]", l)
	}
}

func TestSplitRuleHandlesQuotedComments(t *testing.T) {
	line := `-A PREROUTING -p tcp -m tcp --dport 8080 -m comment --comment "ipxtun-bip" -j DNAT --to-destination 10.20.20.2:8081`
	got := splitRule(line)
	for _, f := range got {
		if len(f) > 0 && (f[0] == '"' || f[len(f)-1] == '"') {
			t.Fatalf("field %q still carries quotes; iptables would reject it", f)
		}
	}
	found := false
	for i, f := range got {
		if f == "--comment" && i+1 < len(got) && got[i+1] == "ipxtun-bip" {
			found = true
		}
	}
	if !found {
		t.Errorf("comment value not unquoted correctly: %q", got)
	}
}

func BenchmarkSeal(b *testing.B) {
	c, _ := NewCrypto(&Config{EnableEncryption: true, Algorithm: "aes-256-gcm",
		PSK: "pN9m6m0tH3nE3V8xKZ6Lq5yYcW2K1S7QG9u4cF0A8M4=", KDFIterations: 1000})
	cd := newCodec(c, 1, 0, 0, 1500)
	payload := make([]byte, 1320)
	out := make([]byte, 2048)

	b.SetBytes(int64(len(payload)))
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		if _, err := cd.Seal(out, ptData, payload); err != nil {
			b.Fatal(err)
		}
	}
}

func BenchmarkOpen(b *testing.B) {
	c, _ := NewCrypto(&Config{EnableEncryption: true, Algorithm: "aes-256-gcm",
		PSK: "pN9m6m0tH3nE3V8xKZ6Lq5yYcW2K1S7QG9u4cF0A8M4=", KDFIterations: 1000})
	enc := newCodec(c, 1, 0, 0, 1500)
	dec := newCodec(c, 2, 1, 0, 1500)
	payload := make([]byte, 1320)
	frame, _ := enc.Seal(make([]byte, 2048), ptData, payload)
	out := make([]byte, 2048)

	b.SetBytes(int64(len(payload)))
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		if _, _, _, _, err := dec.Open(out, frame); err != nil {
			b.Fatal(err)
		}
	}
}
