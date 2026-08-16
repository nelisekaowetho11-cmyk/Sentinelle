# Sentinelle

[![Licence: GPL-3.0](https://img.shields.io/badge/licence-GPL--3.0-blue.svg)](LICENSE)
[![Android](https://img.shields.io/badge/Android-9%2B-3ddc84.svg)](clients/sentinelle)
[![Windows](https://img.shields.io/badge/Windows-10%2F11-0078d4.svg)](clients/sentinelle)
[![macOS](https://img.shields.io/badge/macOS-10.15%2B-000000.svg)](clients/sentinelle)
[![Linux](https://img.shields.io/badge/Linux-x86--64-f0ad4e.svg)](clients/sentinelle)

A self-hosted VPN stack: a management panel, cross-platform clients, and a
tunnel for getting traffic out of a filtered network.

The three parts are usable separately. Run the panel and hand your users the
apps, use the apps against someone else's panel, or run `ipxtun` on its own to
carry any traffic at all between two servers.

```
┌──────────────┐   VLESS / VMess / Trojan / Shadowsocks   ┌──────────────┐
│   clients    │ ◄──────────────────────────────────────► │  Xray on the │
│ mobile · desk│                                          │  panel host  │
└──────┬───────┘                                          └──────┬───────┘
       │  sign in, fetch configs, report device count            │
       ▼                                                         │
┌──────────────┐                                                 │
│    panel     │ ── generates the Xray config, tracks quota ─────┘
│ Flask + React│
└──────────────┘

                     ipxtun (optional, separate)
        server A  ◄────── raw IP / ICMP tunnel ──────►  server B
        in a filtered network                          outside it
```

| Project | What it is | Language |
|---|---|---|
| [`panel/`](panel) | Web panel: users, inbounds, quotas, subscriptions, resellers | Python (Flask) + React |
| [`clients/sentinelle/`](clients/sentinelle) | VPN client for Android, Windows, macOS and Linux | Dart (Flutter) |
| [`ipxtun/`](ipxtun) | Encrypted tunnel over raw IP or ICMP, for filtered networks | Go |

---

## What each part does

### Panel

Creates and manages VPN users. Generates the Xray configuration from what you
set up in the UI, restarts the core when it changes, and tracks per-user traffic
against a quota. Users get either a subscription URL, an app login, or both.

Also manages **resellers** and **admins**: a reseller sells accounts from your
capacity without seeing anyone else's, and an admin manages a group of
resellers. That is what makes it usable as a business rather than a personal
tool.

Installs and updates Xray itself, and can install a handful of tunnel tools
(backhaul, frp, gost, rathole) on a second server for forwarding.

### Clients

One Flutter codebase, two very different cores, chosen because each platform
has a different best answer:

- **Android** — Xray, through a fork of `flutter_v2ray`, on top of `VpnService`.
- **Windows** — sing-box, in either proxy mode or a full TUN tunnel.

Sign in with a panel account, paste a subscription link, or paste raw
`vless://` / `vmess://` / `trojan://` / `ss://` configs. All three can be used at
once and appear in one list.

### ipxtun

A tunnel between two servers that does not use TCP or UDP ports at all. It
encapsulates traffic in raw IP packets with a chosen protocol number, or inside
ICMP echo replies, which tends to survive filtering that blocks everything else.
AES-256-GCM with a pre-shared key, a TUN device on each end, and port forwarding
on top.

Independent of the rest of the stack — it will carry any traffic you point at it.

---

## Getting started

Each project has its own README with real instructions:

- **[panel/README.md](panel/README.md)** — install on a VPS, first login, creating users
- **[clients/sentinelle/README.md](clients/sentinelle/README.md)** — building the Android APK and the desktop clients
- **[ipxtun/README.md](ipxtun/README.md)** — configuration and deployment

The fastest path to something working:

```bash
# 1. Panel, on a VPS with a public IP
cd panel
python3 -m venv venv && ./venv/bin/pip install -r requirements.txt
./venv/bin/python app.py          # → http://0.0.0.0:5000, admin / admin123
```

Change that password before doing anything else. Then add an inbound, add a
user, and either give them the subscription URL or build the client and sign in
with the `pvb…` credentials the panel generated.

---

## Security notes

Read these before running this anywhere real.

- **The default login is `admin` / `admin123`.** It is created on first start so
  you can get in. Change it immediately, and do not expose the panel on a public
  port until you have.
- **The panel stores VPN passwords in clear text**, deliberately: an operator has
  to be able to read a customer's password back to them. Treat the database as a
  secret, and take backups accordingly.
- **Put TLS in front of the panel.** It ships plain HTTP on port 5000 and expects
  a reverse proxy. Credentials cross the network on every sign-in.
- **`ipxtun` needs `CAP_NET_RAW` or root** — it writes raw IP packets. Its
  pre-shared key is the only thing authenticating a peer; generate a fresh one
  per deployment with `openssl rand -base64 32`.
- The example configs in `ipxtun/configs/` use RFC 5737 documentation addresses
  (`203.0.113.x`, `198.51.100.x`) and placeholder keys. They will not work until
  you put your own values in.

---

## Licence

[GPL-3.0](LICENSE). If you distribute a modified version, the source has to go
with it — including if you run a modified panel as a service for other people.

Third-party components keep their own licences:

| Component | Licence | Where |
|---|---|---|
| [Xray-core](https://github.com/XTLS/Xray-core) | MPL-2.0 | downloaded by the panel at runtime; bundled in the Android client as `libv2ray.aar` |
| [sing-box](https://github.com/SagerNet/sing-box) | GPL-3.0 | downloaded by the Windows client on first run |
| [flutter_v2ray](https://github.com/blueboytm/flutter_v2ray) by Arshia Eihami | MIT | vendored and patched at `clients/sentinelle/packages/flutter_v2ray` |
| [Natural Earth](https://www.naturalearthdata.com/) country outlines | public domain | the client's world map |

The `flutter_v2ray` fork is not upstream. It repaints the ongoing notification
with live throughput, and adds `setConnectionMode` so switching between proxy
and tunnel modes stops the previous service first. Both changes are described
in the client README.

---

<sub>Source: <https://github.com/miredaw/Sentinelle> ·
Site: <https://sentinelle.mireda.app></sub>
