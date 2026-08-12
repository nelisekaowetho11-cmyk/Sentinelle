# Sentinelle client

VPN client for Android and Windows, in one Flutter codebase.

Sign into a [Sentinelle panel](../../panel), paste a subscription link from any
panel, or paste raw configs. All three work at once and land in a single list of
locations.

```
Android   Xray, via a patched flutter_v2ray, on top of VpnService
Windows   sing-box, in proxy mode or a full TUN tunnel
```

---

## Features

- **A map, not a dropdown** — every location on a world map with live latency,
  drawn with a Natural Earth projection rather than an image
- **Three kinds of source** — panel accounts, subscription URLs, pasted
  `vless://` / `vmess://` / `trojan://` / `ss://` configs, mixed freely
- **Leak guards** — force DNS through the tunnel, drop IPv6, block WebRTC's STUN
  discovery, silence mDNS/NetBIOS, optionally refuse QUIC; the app reports which
  are actually holding
- **Split tunnelling** — include or exclude apps (Android), or bind individual
  processes to their own exit (Windows)
- **Recovery** — notices a dropped tunnel and reconnects with backoff; on
  Windows it can hold the system proxy closed so traffic fails rather than
  leaking
- **Home screen widget and quick settings tile** (Android), **system tray with
  recent/favourite/fastest locations** (Windows)

---

## Building

You need [Flutter](https://docs.flutter.dev/get-started/install) with a Dart SDK
of at least **3.11.4**.

```bash
cd clients/sentinelle
flutter pub get
```

### Android

There are two product flavours and **`sideload` is the one you want**:

```bash
flutter build apk --release --flavor sideload
# → build/app/outputs/flutter-apk/app-sideload-release.apk
```

| Flavour | applicationId | Self-update | For |
|---|---|---|---|
| `sideload` | `app.veil.veil_client` | yes | handing the APK out yourself |
| `play` | `app.Mireda.Sentinelle` | removed | the maintainer's Google Play listing |

`--flavor` is required; there is no default Android build.

The `play` flavour exists because Google Play forbids an app it distributes from
updating itself, so that variant has the updater stripped in three places — the
manifest, `BuildConfig.SELF_UPDATE`, and a Dart flag. **If you fork this, change
the `play` applicationId in `android/app/build.gradle.kts`** or delete the
flavour; `app.Mireda.Sentinelle` belongs to the upstream listing.

For a debug run:

```bash
flutter run --flavor sideload
```

### Windows

```bash
flutter build windows --release
# → build/windows/x64/runner/Release/Sentinelle.exe
```

sing-box is not bundled. The app downloads it on first use, or you can point at
an existing binary in Settings.

### Both, plus checks

`tool/build_release.ps1` builds every target and verifies the Play bundle has
not accidentally kept the updater:

```powershell
.\tool\build_release.ps1              # sideload + play + windows
.\tool\build_release.ps1 -Only sideload
```

---

## Signing

Debug-key builds are fine for local use. For anything you distribute:

Create `android/key.properties` — it is git-ignored, and it holds a password in
plain text, so keep it out of version control:

```properties
storeFile=my-upload-key.jks
storePassword=…
keyAlias=upload
keyPassword=…
```

Generate the keystore next to it:

```bash
keytool -genkeypair -v -keystore android/my-upload-key.jks \
  -keyalg RSA -keysize 4096 -validity 10000 -alias upload
```

Without `key.properties` the release build falls back to the debug key and still
works — it just cannot be published.

> **The sideload flavour deliberately uses the debug key**, and changing that
> would break every existing install. Android refuses an update whose signing
> certificate differs from the installed one, so a sideloaded app signed with a
> new key fails with "App not installed" and the user has to uninstall — losing
> their accounts — to recover. That makes `~/.android/debug.keystore` as
> important as any release key on this project. **Back it up.**

---

## How it works

### Two cores, on purpose

Android runs **Xray** through a fork of
[`flutter_v2ray`](https://github.com/blueboytm/flutter_v2ray), vendored at
`packages/flutter_v2ray` and wired in with `dependency_overrides`. Two changes
against upstream:

- the ongoing notification is repainted every second with live throughput,
  instead of being built once and never touched
- `setConnectionMode` stops the running service before switching between proxy
  and tunnel modes, because `AppConfigs.V2RAY_CONNECTION_MODE` is a process-wide
  static that upstream only ever sets

Windows runs **sing-box**, which handles a TUN device and per-process routing
that Xray on desktop does not.

### Things that are not obvious

Collected here because each one cost real time to find, and they all present
identically — "the VPN says connected and nothing loads".

- **`useLegacyPackaging = true` is mandatory on Android.** `flutter_v2ray`
  *executes* `libtun2socks.so` with `ProcessBuilder` from `nativeLibraryDir`.
  Modern AGP leaves native libraries compressed inside the APK, so no real file
  is ever written there, the exec fails, and the plugin swallows it. The TUN
  device is still established, so Android reports a working VPN while nothing
  reads the fd. Debug builds hide this — AGP only defaults to non-legacy for
  release.
- **Xray routing must be `AsIs` on Android.** `IPIfNonMatch` pre-resolves
  hostnames through Xray's DNS inside the tunnel and retries on a four-second
  timeout.
- **`dns.servers` must be plain strings**, not objects. The plugin feeds them
  straight to `VpnService.Builder.addDnsServer`.
- **REALITY `dest` needs a small certificate chain.** `www.microsoft.com` has an
  8 KB chain that overflows REALITY's handshake buffer; no client can connect to
  an inbound configured that way. `www.cloudflare.com:443` works.
- **Turning the Windows system proxy off** needs
  `INTERNET_OPTION_PER_CONNECTION_OPTION`, not just `ProxyEnable=0` — WinINet
  keeps its own flag in `DefaultConnectionSettings` and readers follow that.
- **A port being open only means the core started.** Both engines prove the
  tunnel carries a real request before reporting "connected", because sing-box
  and Xray both bind their inbounds before speaking to the server.

### Layout

```
lib/
  main.dart              app root, theme, window and lifecycle
  state/app_state.dart   single source of truth
  models/                ServerConfig, Profile, LocationSource
  services/
    api.dart             panel client
    source_registry.dart accounts + subscriptions + pasted configs, merged
    geo/                 Natural Earth projection and country outlines
    vpn/
      android_engine.dart  Xray via flutter_v2ray
      desktop_engine.dart  sing-box
      leak_guard.dart      DNS / IPv6 / WebRTC / LAN / QUIC probes
  screens/
  widgets/map/           the map is painted, not composed from widgets
packages/flutter_v2ray/  vendored fork (MIT, Arshia Eihami)
tool/                    release build and screenshot scripts
test/                    141 tests, including rendered map/screen checks
```

---

## Tests

```bash
flutter test
flutter analyze
```

Some tests dump PNGs so layout can be eyeballed:

```bash
VEIL_SHOT_DIR=/tmp/shots flutter test test/locations_screen_test.dart
```

Fonts are not available under `flutter test`, so text renders as boxes — judge
geometry and layout from those images, not typography.

---

## Licence

[GPL-3.0](../../LICENSE), except `packages/flutter_v2ray`, which stays MIT under
its original copyright (Arshia Eihami) with our patches on top.
