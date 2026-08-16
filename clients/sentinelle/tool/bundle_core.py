#!/usr/bin/env python3
"""Download the sing-box core and drop it next to a built desktop app.

The desktop client looks for its core beside its own executable first, so
running this after `flutter build <platform>` produces a build that works with
no download at first run — useful when the machines you ship to cannot reach
GitHub.

    python bundle_core.py                       # auto-detect the build output
    python bundle_core.py --dest path/to/dir    # explicit destination
    python bundle_core.py --version 1.13.18     # pin a version
"""

from __future__ import annotations

import argparse
import io
import json
import os
import platform
import shutil
import sys
import tarfile
import urllib.request
import zipfile

PINNED = "1.13.18"
REPO = "SagerNet/sing-box"

MIRRORS = (
    "https://github.com/{repo}/releases/download/v{v}/{asset}",
    "https://ghfast.top/https://github.com/{repo}/releases/download/v{v}/{asset}",
    "https://gh-proxy.com/https://github.com/{repo}/releases/download/v{v}/{asset}",
    "https://ghproxy.net/https://github.com/{repo}/releases/download/v{v}/{asset}",
)

DEFAULT_DESTS = {
    "windows": "veil_client/build/windows/x64/runner/Release",
    "linux": "veil_client/build/linux/x64/release/bundle",
    "darwin": "veil_client/build/macos/Build/Products/Release/veil_client.app/Contents/MacOS",
}


def host_os() -> str:
    s = sys.platform
    if s.startswith("win"):
        return "windows"
    if s == "darwin":
        return "darwin"
    return "linux"


def host_arch() -> str:
    m = platform.machine().lower()
    if m in ("arm64", "aarch64"):
        return "arm64"
    return "amd64"


def asset_name(version: str) -> str:
    os_name = host_os()
    # sing-box publishes macOS builds under "darwin", and as tarballs — Windows
    # is the only platform that gets a .zip. Asking for a darwin .zip is a 404
    # down every mirror, which is the same mistake the Dart core downloader
    # made until it was fixed.
    ext = "zip" if os_name == "windows" else "tar.gz"
    return f"sing-box-{version}-{os_name}-{host_arch()}.{ext}"


def latest_version() -> str:
    try:
        req = urllib.request.Request(
            f"https://api.github.com/repos/{REPO}/releases/latest",
            headers={"User-Agent": "veil-bundler", "Accept": "application/vnd.github+json"},
        )
        with urllib.request.urlopen(req, timeout=15) as r:
            return json.load(r)["tag_name"].lstrip("v")
    except Exception as e:
        print(f"  could not reach the release API ({e}); using pinned {PINNED}")
        return PINNED


def download(version: str, asset: str) -> bytes:
    errors = []
    for tpl in MIRRORS:
        url = tpl.format(repo=REPO, v=version, asset=asset)
        try:
            print(f"  trying {url.split('/')[2]} …")
            req = urllib.request.Request(url, headers={"User-Agent": "veil-bundler"})
            with urllib.request.urlopen(req, timeout=90) as r:
                data = r.read()
            if len(data) < 1024:
                raise RuntimeError(f"response too small ({len(data)} bytes)")
            return data
        except Exception as e:
            errors.append(f"{url.split('/')[2]}: {e}")
    raise SystemExit(
        "Could not download sing-box. Tried:\n  "
        + "\n  ".join(errors)
        + f"\n\nDownload {asset} by hand and unzip it into the build folder."
    )


WANTED = {"sing-box", "sing-box.exe", "libcronet.dll", "libcronet.so"}


def extract(data: bytes, asset: str, dest: str) -> list[str]:
    os.makedirs(dest, exist_ok=True)
    written = []
    if asset.endswith(".tar.gz"):
        with tarfile.open(fileobj=io.BytesIO(data), mode="r:gz") as tf:
            for m in tf.getmembers():
                name = os.path.basename(m.name)
                if not m.isfile() or name not in WANTED:
                    continue
                src = tf.extractfile(m)
                if src is None:
                    continue
                out = os.path.join(dest, name)
                with open(out, "wb") as f:
                    shutil.copyfileobj(src, f)
                written.append(out)
    else:
        with zipfile.ZipFile(io.BytesIO(data)) as zf:
            for info in zf.infolist():
                name = os.path.basename(info.filename)
                if info.is_dir() or name not in WANTED:
                    continue
                out = os.path.join(dest, name)
                with open(out, "wb") as f:
                    f.write(zf.read(info))
                written.append(out)

    for path in written:
        if os.path.basename(path).startswith("sing-box") and not path.endswith(".dll"):
            os.chmod(path, 0o755)
    return written


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--dest", help="folder to place the core in")
    ap.add_argument("--version", help="sing-box version (default: latest)")
    args = ap.parse_args()

    here = os.path.dirname(os.path.abspath(__file__))
    dest = args.dest or os.path.join(here, DEFAULT_DESTS[host_os()])
    dest = os.path.abspath(dest)

    if not args.dest and not os.path.isdir(dest):
        raise SystemExit(
            f"Build output not found at:\n  {dest}\n\n"
            "Build the app first (flutter build windows/linux/macos --release), "
            "or pass --dest."
        )

    version = args.version or latest_version()
    asset = asset_name(version)
    print(f"sing-box {version} for {host_os()}/{host_arch()}")
    print(f"  asset: {asset}")

    data = download(version, asset)
    written = extract(data, asset, dest)
    if not written:
        raise SystemExit("archive did not contain a sing-box binary")

    print(f"\nInstalled into {dest}:")
    for p in written:
        print(f"  {os.path.basename(p)}  ({os.path.getsize(p):,} bytes)")
    print("\nThe app will find this automatically — no download needed at first run.")


if __name__ == "__main__":
    main()
