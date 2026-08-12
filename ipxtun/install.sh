#!/usr/bin/env bash
# ipxtun installer: builds the tunnel from source on this machine.
# No network calls to any vendor, no licence check, no phone-home.
set -euo pipefail

PREFIX="${PREFIX:-/usr/local/bin}"
CONFDIR="${CONFDIR:-/etc/ipxtun}"
GO_VERSION="${GO_VERSION:-1.23.4}"
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
blue()  { printf '\033[36m%s\033[0m\n' "$*"; }

[[ $EUID -eq 0 ]] || { red "run as root"; exit 1; }

blue "==> checking for a Go toolchain"
GO_BIN=""
if command -v go >/dev/null 2>&1; then
    GO_BIN="$(command -v go)"
elif [[ -x /usr/local/go/bin/go ]]; then
    GO_BIN=/usr/local/go/bin/go
fi

if [[ -n "$GO_BIN" ]]; then
    green "    found $($GO_BIN version)"
else
    blue "==> installing Go ${GO_VERSION}"
    case "$(uname -m)" in
        x86_64)          GOARCH=amd64 ;;
        aarch64|arm64)   GOARCH=arm64 ;;
        *) red "unsupported architecture: $(uname -m)"; exit 1 ;;
    esac
    TMP="$(mktemp -d)"
    trap 'rm -rf "$TMP"' EXIT
    URL="https://go.dev/dl/go${GO_VERSION}.linux-${GOARCH}.tar.gz"
    if ! curl -fsSL --retry 3 -o "$TMP/go.tgz" "$URL"; then
        red "could not download $URL"
        red "install Go manually (apt install golang-go) and re-run this script"
        exit 1
    fi
    rm -rf /usr/local/go
    tar -C /usr/local -xzf "$TMP/go.tgz"
    GO_BIN=/usr/local/go/bin/go
    green "    installed $($GO_BIN version)"
fi

blue "==> building ipxtun"
cd "$SRC_DIR"
export GOFLAGS=-mod=mod
export CGO_ENABLED=0
# A static binary with no external modules: nothing to resolve at build time.
"$GO_BIN" build -trimpath -ldflags "-s -w" -o "$SRC_DIR/ipxtun" .
green "    built $(du -h "$SRC_DIR/ipxtun" | cut -f1) binary"

blue "==> running self-tests"
if "$GO_BIN" test -count=1 ./... >/dev/null 2>&1; then
    green "    crypto, config and framing tests pass"
else
    red "    self-tests FAILED - not installing"
    "$GO_BIN" test -count=1 ./... || true
    exit 1
fi

blue "==> installing"
install -m 0755 "$SRC_DIR/ipxtun" "$PREFIX/ipxtun"
install -d -m 0700 "$CONFDIR"

if [[ -d "$SRC_DIR/configs" ]]; then
    for f in "$SRC_DIR"/configs/*.toml; do
        [[ -e "$f" ]] || continue
        dest="$CONFDIR/$(basename "$f")"
        if [[ -e "$dest" ]]; then
            echo "    keeping existing $dest"
        else
            install -m 0600 "$f" "$dest"
            echo "    installed $dest"
        fi
    done
fi

if [[ -f "$SRC_DIR/ipxtunctl" ]]; then
    install -m 0755 "$SRC_DIR/ipxtunctl" "$PREFIX/ipxtunctl"
fi

modprobe tun 2>/dev/null || true
grep -qx tun /etc/modules 2>/dev/null || echo tun >> /etc/modules 2>/dev/null || true
modprobe tcp_bbr 2>/dev/null || true

green ""
green "ipxtun $("$PREFIX/ipxtun" -v) installed"
green ""
echo "Configs live in $CONFDIR. Next steps:"
echo "  1. edit the config for this box (listen_ip must be THIS server's public IP)"
echo "  2. ipxtun -c $CONFDIR/iran_bip.toml -check     # validate"
echo "  3. ipxtunctl enable iran_bip                   # start at boot"
echo ""
echo "The PSK must be identical on both servers, and different from anyone else's."
echo "Generate one with:  ipxtun -genpsk"
