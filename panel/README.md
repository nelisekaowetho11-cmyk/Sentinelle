# Sentinelle Panel

Web panel for running an Xray-based VPN service: users, inbounds, quotas,
subscriptions, and a reseller hierarchy so other people can sell from your
capacity without seeing each other's customers.

It generates the Xray configuration from what you set up in the UI, restarts the
core when anything changes, and meters traffic per user.

```
Flask + SQLAlchemy  ·  SQLite  ·  React (no build step)  ·  102 HTTP routes
```

---

## What it does

**Users** — create accounts with a traffic quota, an expiry, a device limit and
a speed limit. Each gets a UUID for the Xray inbounds, a subscription URL, and a
`pvb…` username and password for the client apps. You can restrict an account to
the subscription link only, the app only, or allow both.

**Inbounds** — VLESS, VMess, Trojan and Shadowsocks over TCP, WebSocket, gRPC,
HTTPUpgrade, XHTTP or mKCP, with REALITY or TLS. The panel writes the Xray config
and reloads the core.

**Subscriptions** — a `/sub/<token>` URL per user, base64 config list for VPN
clients and a rendered status page for browsers. The path, domain, scheme and
port are configurable, and you can add relay hosts that serve the same
subscription from another address.

**Resellers and admins** — three tiers. A *superadmin* runs everything; an
*admin* manages a set of resellers; a *reseller* manages only their own users,
against a quota of accounts and traffic that you allocate. Resellers cannot see
each other.

**Servers and tunnels** — register other boxes and install forwarding between
them (backhaul, frp, gost, rathole, HAProxy, iptables). Useful when the machine
users connect to is not the machine running Xray.

**Client API** — `/api/client/*`, used by the Sentinelle apps for sign-in,
config delivery, quota and device-limit enforcement.

---

## Requirements

- Linux with a public IP (tested on Debian/Ubuntu)
- Python 3.10 or newer
- root, or a user that can bind low ports and manage the Xray process

Xray itself is **not** in this repository. The panel downloads the right build
for your architecture from the [Xray-core
releases](https://github.com/XTLS/Xray-core/releases) on first start, into
`bin/`. The optional tunnel tools are fetched the same way, into `binaries/`.

---

## Install

```bash
git clone https://github.com/miredaw/Sentinelle.git
cd Sentinelle/panel

python3 -m venv venv
./venv/bin/pip install -r requirements.txt
./venv/bin/python app.py
```

First start creates `instance/panel.db`, writes a session key to `.secret_key`,
downloads Xray, and prints:

```
  Default credentials → admin / admin123
  Panel → http://0.0.0.0:5000
```

**Change that password before you expose the port.** Settings → Admins.

### Run it as a service

`xray-panel.service` is included. Adjust the paths to match where you cloned it:

```ini
[Service]
WorkingDirectory=/opt/sentinelle/panel
ExecStart=/opt/sentinelle/panel/venv/bin/python3 /opt/sentinelle/panel/app.py
Environment=PORT=5000
```

```bash
sudo cp xray-panel.service /etc/systemd/system/
sudo systemctl daemon-reload && sudo systemctl enable --now xray-panel
sudo journalctl -u xray-panel -f
```

### Put TLS in front of it

The panel serves plain HTTP and expects a reverse proxy. Do not skip this — the
sign-in sends a password, and so does every client app.

```nginx
server {
    listen 443 ssl;
    server_name panel.example.com;

    ssl_certificate     /etc/letsencrypt/live/panel.example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/panel.example.com/privkey.pem;

    location / {
        proxy_pass http://127.0.0.1:5000;
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

`X-Forwarded-For` matters: the panel uses the client address for the device
registry and to show users where they are connecting from. Without it every user
appears to be on 127.0.0.1.

---

## First run

1. **Change the admin password.** Settings → Admins.
2. **Set the server address.** Settings → the public IP or hostname users will
   connect to. It goes into every generated config, so getting it wrong means
   nothing connects.
3. **Create an inbound.** VLESS + REALITY over TCP is the sensible default.
   For REALITY, the `dest` must be a TLS 1.3 site with a **small certificate
   chain** — `www.cloudflare.com:443` works. `www.microsoft.com` does not: its
   chain is over 8 KB and overflows REALITY's handshake buffer, and no client
   can connect. This is the single most common way to get a config that looks
   correct and never works.
4. **Create a user**, assign the inbound, set a quota.
5. Hand them the subscription URL, or the app username and password.

---

## Configuration

Environment variables:

| Variable | Default | What it does |
|---|---|---|
| `PORT` | `5000` | HTTP port |
| `XRAY_BINARY` | `./bin/xray-linux-amd64` | path to the Xray executable |

Everything else lives in Settings and is stored in the database — server
address, subscription domain and path, backup schedule, branding.

---

## Layout

```
app.py              everything: models, routes, Xray config generation, tunnels
requirements.txt
xray-panel.service
static/*.jsx        React, compiled in the browser by Babel standalone
static/style.css
templates/*.html    Jinja shells; app.html loads the React bundle
tests/
```

There is no frontend build step. The `.jsx` files are served as
`type="text/babel"` and compiled client-side, so editing one and reloading is
the whole workflow. React and Babel come from unpkg, which means **the panel UI
needs internet on the browser side** — worth knowing if you administer it from a
restricted network.

`app.py` is one large module on purpose: it is deployed by copying a single file
to a server, and keeping it self-contained is what makes that safe.

---

## Backups

The panel takes periodic backups of the database on its own; the schedule is in
Settings. To back it up yourself, the whole state is one file:

```bash
sqlite3 instance/panel.db ".backup '/root/panel-$(date +%F).db'"
```

Keep those somewhere private. The database holds VPN passwords in clear text —
deliberately, so an operator can read a customer's password back to them — which
also means a leaked backup is a leak of every account.

---

## Security

- Change the default password before exposing the port.
- Terminate TLS in front of it.
- The database is a secret. So are its backups.
- `.secret_key` signs Flask sessions. It is generated on first run and is
  git-ignored; deleting it logs everyone out.
- The panel runs Xray as a child process and writes its config. Only give the
  panel account the privileges it actually needs.
