# ipxtun

A point-to-point encrypted tunnel between two Linux servers, built to replace the
Backhaul Premium `ipx`/`tun` setup. Same idea, same config shape, original code:
no licence, no activation, no server to call home to, and nothing that can decide
to disconnect you every ten seconds.

Written in Go with **zero external dependencies** — it builds offline with
nothing but a Go toolchain.

## What it does

Both servers get a virtual network interface with a private address
(`10.30.20.1` and `10.30.20.2`). Anything sent to one address comes out the
other side. Every packet is encrypted with AES-256-GCM and wrapped so it does
not look like a tunnel on the wire:

| Profile | What goes on the wire | Use when |
|---|---|---|
| `bip` | Bare IP packets with a custom protocol number. **No port at all.** | Default. Nothing for a port-based filter to match. |
| `icmp` | ICMP echo replies — indistinguishable from ping traffic at a glance | Ports are blocked but ping works |
| `ipip` | Protocol 4 (IP-in-IP) | Provider passes IPIP but not odd protocol numbers |
| `gre` | Protocol 47 with a real GRE header | Provider expects to see GRE |
| `udp` | Ordinary UDP datagrams | Raw sockets unavailable (some VPS/containers), or peer is behind NAT |

On top of that, the Iran side forwards public ports across the tunnel, so
`:8080` on the Iran box reaches `:8081` on the Kharej box.

## Install

Copy this folder to **both** servers, then on each:

```bash
sudo bash install.sh
```

The installer fetches a Go toolchain if one is missing, builds the binary, runs
the test suite, and refuses to install if anything fails. Configs land in
`/etc/ipxtun/`.

## Before you start: generate a key

The configs in `configs/` ship with the placeholder
`REPLACE-ME-run-openssl-rand-base64-32`. **The tunnel will not start until you
replace it.** That is deliberate — a shipped default key is not a key.

```bash
ipxtun -genpsk            # or: openssl rand -base64 32
```

The key must be identical on the two ends of one tunnel, and different from
every other tunnel you run. It is the only thing authenticating a peer: anyone
holding it can decrypt and inject traffic.

If you are migrating from Backhaul Premium, note that its installer script had a
hardcoded default at the "PSK (32-char base64)" prompt, so every deployment
where someone pressed Enter shares one key, and that script gets passed around.
Do not carry it over.

The example addresses in `configs/` are RFC 5737 documentation ranges
(`203.0.113.x`, `198.51.100.x`) and are equally placeholders — put your two
servers' real public IPs in before starting anything.

## Bring a tunnel up

On each server, edit the config so `listen_ip` is **that machine's own public
IP** and `dst_ip` is the other machine's:

```bash
ipxtun -c /etc/ipxtun/iran_bip.toml -check   # validate before starting
ipxtunctl enable iran_bip                     # start now and at every boot
```

Kharej side is the same with `kharej_bip`.

**Leave backhaul running.** The shipped configs are deliberately offset so both
tunnels coexist, letting you compare them on the same link before committing:

| | backhaul | ipxtun |
|---|---|---|
| bip subnet | 10.20.20.0/24 | 10.30.20.0/24 |
| icmp subnet | 10.10.10.0/24 | 10.30.10.0/24 |
| bip2 subnet | 10.20.21.0/24 | 10.30.21.0/24 |
| health ports | 1234 / 1235 / 1236 | 21234 / 21235 / 21236 |
| interfaces | `backhaul-*` | `ipx-*` |
| public ports | 8080, 8040, 8020, 5001 | 18080, 18040, 18020, 15001 |

While both are running you can check nothing has drifted onto a shared value:

```bash
IPXTUN_CHECK_COEXIST=1 go test -run Coexist ./...
```

The one thing that could still overlap is the `bip` protocol number. The configs
use 253 and 254, reserved for experimental use, which backhaul is unlikely to
have chosen. If it did pick the same number, both programs receive copies of
each other's packets and discard them as unauthenticated — wasted CPU and a
climbing `auth_failed` counter, but not a broken tunnel. Change `ip_proto` on
both ends if you see that.

### Testing it without touching your clients

Point a client at the shifted port. If `:8080` on the Iran box reaches your
service today, then `:18080` reaches the same service over the new tunnel:

```bash
curl -v http://203.0.113.10:18080/
ping 10.30.20.2                      # from the Iran box
ipxtunctl stats iran_bip             # watch the counters move
```

One caveat: the forwarder delivers to the peer's *new* tunnel address
(`10.30.20.2`). If a service on the Kharej box is bound specifically to the old
`10.20.20.2` rather than to `0.0.0.0`, it will not answer on the new address.
`ss -lntp` on the Kharej box tells you which.

### Cutting over

Once you are satisfied, stop backhaul and move ipxtun onto the real ports:

```bash
systemctl disable --now backhaul-iran1235      # on the Iran box
systemctl disable --now backhaul-kharej1235    # on the Kharej box
```

Then in the Iran config, drop the 10000 offset from the listen side of each
mapping — `18080=8081` becomes `8080=8081`, and so on — and restart:

```bash
ipxtunctl restart iran_bip
```

The tunnel subnets and health ports can stay where they are; nothing outside
the tunnel depends on them.

Taking backhaul's ports is the expected end state, so nothing in the test suite
objects to it. The coexistence check is opt-in and only worth running while both
tunnels are live:

```bash
IPXTUN_CHECK_COEXIST=1 go test -run Coexist ./...
```

After cutover the useful check is the bind itself: if something already holds a
port, startup fails and names it.

### Check it works

```bash
ipxtunctl list             # all tunnels, service state, peer reachability
ipxtunctl stats iran_bip   # packet counters, RTT, forwarder activity
ipxtunctl logs iran_bip    # follow the journal
ping 10.30.20.2            # from the Iran box
```

## Managing tunnels

```
ipxtunctl list                 every config, its service state and peer status
ipxtunctl enable  <name>       create the systemd unit, start at boot
ipxtunctl start|stop|restart <name>
ipxtunctl status  [name]
ipxtunctl logs    <name>       follow the log
ipxtunctl stats   <name>       live counters as JSON
ipxtunctl check   <name>       validate a config without starting
ipxtunctl remove  <name>       stop, disable, optionally delete the config
ipxtunctl newpsk               generate a fresh pre-shared key
```

`<name>` is the config filename without `.toml`, e.g. `iran_bip`.

## Config reference

Existing backhaul `ipx` configs are accepted as-is; these are the keys that
matter.

```toml
[transport]
heartbeat_interval = 10     # seconds between keepalives
heartbeat_timeout  = 25     # peer considered unreachable after this

[tun]
name        = "ipx-bip"         # interface name (max 15 chars)
local_addr  = "10.30.20.1/24"   # this end
remote_addr = "10.30.20.2/24"   # other end, must be in the same subnet
health_port = 21235         # HTTP status endpoint, bound to local_addr only
mtu         = 1320

[ipx]
mode      = "server"        # server on the Iran box, client on Kharej
profile   = "bip"           # bip | icmp | ipip | gre | udp
listen_ip = "203.0.113.10" # THIS machine's public IP
dst_ip    = "198.51.100.10"   # the peer's public IP
interface = "eth0"
ip_proto  = 253             # bip only: IP protocol number, must match both ends
icmp_type = 0               # icmp only: 0 = echo reply (recommended)
port      = 8443            # udp only

[security]
enable_encryption = true
algorithm      = "aes-256-gcm"   # or aes-128-gcm
psk            = "..."           # identical on both ends, secret
kdf_iterations = 100000
padding        = 0               # random bytes per packet to blur size patterns

[tuning]
auto_tuning    = true
tuning_profile = "balanced"      # balanced | fast | latency | resource
workers        = 0               # 0 = one per CPU core
channel_size   = 4096

[logging]
log_level = "info"               # trace | debug | info | warn | error

[ports]                          # server side only
forwarder = "native"             # native (TCP+UDP, in-process) | iptables | none
mapping = [
    "8080=8081",                 # listen 8080, deliver to peer's 8081
    "443",                       # same port both sides
    "9000-9010",                 # a range
    "7000-7100:5201",            # a range collapsed onto one port
]
```

### MTU

The encapsulation adds a fixed amount per packet:

| Profile | Overhead | Max MTU on a 1500-byte path |
|---|---|---|
| `bip`, `ipip` | 52 bytes | 1448 |
| `gre` | 56 bytes | 1444 |
| `icmp`, `udp` | 60 bytes | 1440 |

The shipped configs use **1320**, matching your current setup — a safe value
that survives PPPoE and other encapsulation along the way. Raising it toward the
maximum gives more throughput per packet, but if the path cannot carry the
larger frames you get a tunnel that passes small packets and silently drops
large ones. Change it on both ends together, then test with:

```bash
ping -M do -s 1292 10.30.20.2
```

(1292 = MTU − 28, the largest payload that fits without fragmenting.)
`ipxtun -check` refuses configurations whose MTU plus overhead cannot fit a
1500-byte path.

## Why this does not disconnect

There is no session to lose. The tunnel is stateless: every packet carries
everything needed to authenticate it, so there is no handshake, no connection
state, and nothing to time out. If the peer reboots, changes address, or drops
off the network for an hour, packets simply start arriving again and the tunnel
resumes — no reconnect, no backoff, no restart.

The heartbeat exists only to measure round-trip time and to report peer
reachability on the health endpoint. If heartbeats stop, the tunnel keeps
listening and keeps working the moment the peer returns.

## Health endpoint

Bound to the tunnel address on `health_port`, never to the public interface.

```
GET /health    {"status":"up","peer":"10.30.20.2","rtt_ms":42.1,...}
GET /stats     full counters as JSON
GET /metrics   Prometheus format
```

`/health` returns HTTP 503 when the peer has gone silent, so it works directly
as a load-balancer or monitoring check.

## Troubleshooting

**Tunnel is up but no traffic.** Check `listen_ip` really is this machine's
address — a mismatch makes the raw socket bind succeed but receive nothing.
`ip -4 addr show eth0` shows the truth. The tunnel warns about this at startup.

**`operation not permitted` on start.** Raw sockets and TUN need root. Also
check the `tun` module is loaded: `modprobe tun`.

**`transport read: protocol not available` / `send failed: ... peer
unreachable`.** Expected while only one side is running. Your heartbeat reached
the far end, nothing there was listening on that IP protocol, and its kernel
answered with ICMP protocol-unreachable — which Linux hands back as
`ENOPROTOOPT` on the next read. It is a statement about the peer, not about
this end. Start the other side and it stops. If it persists once both are up,
the two ends disagree about `ip_proto`, or something between them is dropping
that protocol number.

**Works for small packets, hangs on large transfers.** MTU is too high for the
path. Lower `mtu` on both ends and re-test with the `ping -M do` command above.

**Nothing arrives with the `bip` profile.** Some providers drop uncommon IP
protocol numbers. Try `ip_proto = 4`, `47`, or `94`, or switch the profile to
`icmp` or `udp`. Change it on both ends.

**`address already in use`.** Something already holds that port. The shipped
configs avoid every port backhaul uses, so this usually means you edited one
onto a busy port — `ss -lntp | grep <port>` names the process.

**Peer shows down but traffic flows.** Only the heartbeat is failing — usually
because the two ends have different `heartbeat_timeout` values. Traffic is
unaffected.

Turn up detail with `log_level = "debug"`. Repeated per-packet complaints are
collapsed to one line per second so a scanner cannot flood the journal.

## Performance

Per-packet cost is roughly 370 ns for encrypt or decrypt at 1320 bytes
(~3.5 GB/s per core on a laptop CPU, higher on server silicon), with **zero heap
allocations per packet**.

- The TUN device is opened multi-queue, one queue per worker, so the kernel
  spreads flows across cores with no locking in userspace.
- Each worker sends on its own socket; nothing contends on a shared write lock.
- Receive is deliberately single-socket feeding a decrypt pool. A Linux raw
  socket copies each packet to *every* matching socket, so a pool of receive
  sockets would decrypt everything N times.
- Port forwarding hands TCP connections to the kernel's `splice()`, so forwarded
  bytes are never copied through userspace.

If `pool_stalls` in `ipxtunctl stats` keeps climbing, raise `channel_size` or
`workers`.

## Security notes

- AES-256-GCM, keys derived from the PSK with PBKDF2-HMAC-SHA256, separate keys
  for payload and header.
- The 16-byte header is encrypted too, so every byte on the wire is
  indistinguishable from random. There is no fixed magic number or version byte
  for a DPI box to fingerprint.
- Nonces can never repeat: a random session ID per process, and each worker owns
  a disjoint slice of the counter space.
- A sharded sliding-window filter rejects replayed packets.
- Forged packets are dropped before anything reaches the kernel's network stack.
- With the `udp` profile the peer address is only updated from packets that
  already authenticated, so an off-path spoofer cannot redirect your traffic.

## Running the tests

```bash
go test ./...
```

Covers the wire format round-trip, single-bit tamper rejection across every byte
of a frame, wrong-key rejection, header indistinguishability, the replay window
(including concurrent access), PBKDF2 against published vectors, config parsing
including your original files, and the port-mapping grammar.

## Files

```
main.go                  engine: workers, datapath, lifecycle
config.go / toml.go      config model and a dependency-free TOML reader
crypto.go                AEAD framing, KDF, nonces, replay window
tun_linux.go             multi-queue TUN device
transport_raw_linux.go   bip / icmp / ipip / gre raw sockets
transport.go             transport interface and the UDP profile
forward.go               TCP and UDP port forwarding
iptables_linux.go        netfilter forwarder
tuning_linux.go          kernel tuning profiles
health.go                health and metrics endpoint
install.sh               build and install
ipxtunctl                service management
configs/                 drop-in replacements for your existing configs
```

## Licence

[GPL-3.0](../LICENSE). Part of the [Sentinelle](..) stack, but independent of
it — ipxtun will carry any traffic you point at it.
