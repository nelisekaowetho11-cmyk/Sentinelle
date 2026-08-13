import 'dart:async';
import 'dart:io';

import 'package:flutter_v2ray/flutter_v2ray.dart';

import '../../models/models.dart';
import '../xray_config.dart';
import 'android_shortcuts.dart';
import 'reachability.dart';
import 'vpn_engine.dart';

/// Android implementation — VpnService + tun2socks via `flutter_v2ray`.
class AndroidVpnEngine implements VpnEngine {
  AndroidVpnEngine() {
    _v2ray = FlutterV2ray(onStatusChanged: _onStatus);
  }

  late final FlutterV2ray _v2ray;
  bool _initialized = false;

  final _stateCtrl = StreamController<VpnState>.broadcast();
  final _statsCtrl = StreamController<VpnStats>.broadcast();

  VpnState _state = VpnState.disconnected;
  VpnStats _stats = VpnStats.zero;

  /// Set while we are asking the core to start, so an early "DISCONNECTED"
  /// callback doesn't flip the UI back before the tunnel is really up.
  bool _starting = false;

  /// Set between the plugin reporting CONNECTED and our own verification
  /// finishing.
  ///
  /// The plugin flips to CONNECTED the moment the core's run loop starts,
  /// which says nothing about whether traffic moves. Reporting that straight
  /// through is what made the app claim a working tunnel that carried nothing.
  bool _verifying = false;

  /// The server the running core was started for. Guards [measureDelay] from
  /// answering with the *current* tunnel's latency when asked about a
  /// different location.
  String? _activeKey;

  /// Fails the attempt if the core never reports CONNECTED.
  ///
  /// Without it a start that silently went nowhere left the engine in
  /// `connecting` forever, and because the UI disables the picker while busy
  /// the user could not choose another location either.
  Timer? _watchdog;
  static const _startTimeout = Duration(seconds: 25);

  static String _key(ServerConfig s) => '${s.address}:${s.port}';

  @override
  Stream<VpnState> get stateStream => _stateCtrl.stream;
  @override
  Stream<VpnStats> get statsStream => _statsCtrl.stream;
  @override
  VpnState get state => _state;
  @override
  VpnStats get stats => _stats;

  void _emitState(VpnState s) {
    if (_state == s) return;
    _state = s;
    if (!_stateCtrl.isClosed) _stateCtrl.add(s);
  }

  void _onStatus(V2RayStatus status) {
    _stats = VpnStats(
      uploadSpeed: status.uploadSpeed,
      downloadSpeed: status.downloadSpeed,
      uploadTotal: status.upload,
      downloadTotal: status.download,
      duration: _parseDuration(status.duration),
    );
    if (!_statsCtrl.isClosed) _statsCtrl.add(_stats);

    switch (status.state.toUpperCase()) {
      case 'CONNECTED':
        _starting = false;
        // Stay on "connecting" until the tunnel has proved it carries
        // traffic. The plugin means "the core is running", not "this works".
        if (!_verifying) _emitState(VpnState.connected);
        break;
      case 'CONNECTING':
        _emitState(VpnState.connecting);
        break;
      case 'DISCONNECTED':
        if (!_starting) {
          _verifying = false;
          _cancelWatchdog();
          _emitState(VpnState.disconnected);
        }
        break;
    }
  }

  void _cancelWatchdog() {
    _watchdog?.cancel();
    _watchdog = null;
  }

  static Duration _parseDuration(String hms) {
    final parts = hms.split(':');
    if (parts.length != 3) return Duration.zero;
    return Duration(
      hours: int.tryParse(parts[0]) ?? 0,
      minutes: int.tryParse(parts[1]) ?? 0,
      seconds: int.tryParse(parts[2]) ?? 0,
    );
  }

  @override
  Future<void> initialize() async {
    if (_initialized) return;
    await _v2ray.initializeV2Ray(
      notificationIconResourceType: 'mipmap',
      notificationIconResourceName: 'ic_launcher',
    );
    _initialized = true;
  }

  /// Tears down a tunnel the previous run left behind.
  ///
  /// Android keeps a VpnService alive after the activity dies, so a crash
  /// leaves the device tunnelling through a core this process knows nothing
  /// about — connected, unmanageable, and invisible in the app's own state.
  /// Stopping unconditionally is safe: with nothing running it is a no-op.
  /// Returns true when a tunnel was already up and has been left running.
  ///
  /// The sweep used to stop the core unconditionally, on the reasoning that
  /// anything still running at startup was left behind by a crash. That is
  /// wrong whenever the app is *cold-started while connected* — which happens
  /// every time someone taps the ongoing notification, and which took the
  /// tunnel down with it.
  ///
  /// A core that reports CONNECTED is not an orphan, it is a working tunnel;
  /// the app adopts it instead. Only a core in some other state — starting,
  /// half-dead, wedged — is swept.
  static Future<bool> sweepOrphans() async {
    try {
      if (await AndroidShortcuts.isCoreRunning()) return true;

      final v2ray = FlutterV2ray(onStatusChanged: (_) {});
      await v2ray.initializeV2Ray(
        notificationIconResourceType: 'mipmap',
        notificationIconResourceName: 'ic_launcher',
      );
      await v2ray.stopV2Ray();
      return false;
    } catch (_) {
      // Never let a failed sweep stop the app from starting.
      return false;
    }
  }

  /// Takes ownership of a tunnel that was already running when the app opened.
  ///
  /// Without this the engine would sit on `disconnected` while the phone was
  /// plainly tunnelling — the state the sweep used to "fix" by killing it.
  void adoptRunningTunnel() {
    _starting = false;
    _verifying = false;
    _emitState(VpnState.connected);
  }

  @override
  Future<bool> isReady() async => _initialized;

  @override
  Future<bool> requestPermission() => _v2ray.requestPermission();

  String _config(ServerConfig server, VpnEngineOptions o) =>
      XrayConfigBuilder(
        socksPort: o.socksPort,
        httpPort: o.httpPort,
        dnsServers: o.dnsServers,
        bypassLan: o.bypassLan,
        blockAds: o.blockAds,
        forceTunnel: o.forceTunnel,
        forceDirect: o.forceDirect,
        dnsGuard: o.dnsGuard,
        ipv6Guard: o.ipv6Guard,
        webRtcGuard: o.webRtcGuard,
        lanGuard: o.lanGuard,
        quicGuard: o.quicGuard,
      ).buildJson(server);

  /// Android's VpnService can only *exclude* packages, so "only these apps"
  /// is expressed as "exclude everything the user did not pick" — which we
  /// cannot enumerate — and is therefore surfaced as exclusion only.
  List<String>? _blockedApps(VpnEngineOptions o) {
    final apps = o.splitApps.where((a) => a.trim().isNotEmpty).toList();
    if (apps.isEmpty || o.splitMode == SplitMode.all) return null;
    return o.splitMode == SplitMode.exceptListed ? apps : null;
  }

  /// The last verification failure, surfaced to the UI.
  @override
  String? lastFailure;

  /// Proxy-only runs the core with local SOCKS/HTTP listeners and no
  /// VpnService, so nothing is routed unless an app is pointed at the port.
  /// Useful when the device will not grant the VPN permission, or when only
  /// one app should go through the tunnel.
  bool _proxyOnly = false;

  /// Which mode the previous run used, or null before the first one. Only used
  /// to notice a switch between the two Android services.
  bool? _lastProxyOnly;

  /// Raised whenever an attempt starts, is superseded, or is cancelled.
  ///
  /// Verification runs unawaited and takes up to twenty seconds — three delay
  /// probes and three reachability probes. Without a generation to check
  /// against, a user who gave up and pressed stop got the *previous* attempt's
  /// verdict landing on top of them a quarter of a minute later, as a red
  /// failure panel for a connection they had already abandoned.
  int _generation = 0;

  @override
  Future<void> connect(ServerConfig server, VpnEngineOptions options) async {
    final generation = ++_generation;
    await initialize();
    if (generation != _generation) return;
    _proxyOnly = options.mode == TunnelMode.proxy;
    _socksPort = options.socksPort;

    // Only the full tunnel needs the system's blessing; proxy mode is just a
    // listener on localhost.
    if (!_proxyOnly && !await requestPermission()) {
      _emitState(VpnState.disconnected);
      throw Exception('VPN permission was denied');
    }
    if (generation != _generation) return;

    // The two modes are two different Android services. Starting a run in the
    // other one takes the old service down, and for a moment both cores want
    // the same local SOCKS port — so wait for the first to actually let go
    // rather than racing it and failing to bind.
    if (_lastProxyOnly != null &&
        _lastProxyOnly != _proxyOnly &&
        _state != VpnState.disconnected) {
      await disconnect();
      await Future<void>.delayed(const Duration(milliseconds: 600));
      // disconnect() raises the generation, so this attempt has to reclaim it
      // rather than mistake its own teardown for a cancel.
      if (generation != _generation - 1) return;
      _generation = generation;
    }
    _lastProxyOnly = _proxyOnly;

    _starting = true;
    _verifying = true;
    _activeKey = _key(server);
    lastFailure = null;
    _emitState(VpnState.connecting);

    // Nothing below is allowed to leave the engine stuck on "connecting":
    // that state disables the location picker, which is how a failed start
    // turned into "I cannot choose anywhere else either".
    _cancelWatchdog();
    _watchdog = Timer(_startTimeout, () {
      if (_state == VpnState.connecting) {
        unawaited(_failVerification(
          'The tunnel did not come up within '
          '${_startTimeout.inSeconds} seconds. Try another location.',
        ));
      }
    });

    final configJson = _config(server, options);
    final remark = server.name.isEmpty ? server.tag : server.name;
    // Mirrored where the tile and widget can read it: they may be tapped when
    // this process is long gone.
    unawaited(AndroidShortcuts.rememberConnection(
      configJson: configJson,
      remark: remark,
      proxyOnly: _proxyOnly,
    ));

    try {
      await _v2ray.startV2Ray(
        remark: remark,
        config: configJson,
        blockedApps: _blockedApps(options),
        bypassSubnets: null,
        proxyOnly: _proxyOnly,
        notificationDisconnectButtonName: 'DISCONNECT',
      );
    } catch (e) {
      _starting = false;
      _verifying = false;
      _cancelWatchdog();
      // A cancel takes the core down underneath the start, so the plugin
      // throws. The user asked for that; it is not a failure to report.
      if (generation != _generation) {
        _emitState(VpnState.disconnected);
        return;
      }
      _emitState(VpnState.error);
      rethrow;
    }

    if (generation != _generation) return;

    // The plugin reports CONNECTED as soon as the core's run loop starts — it
    // says nothing about whether the outbound actually works. Without this
    // check a dead tunnel looks identical to a working one: "connected", no
    // traffic. Prove it carries a request before claiming success.
    unawaited(_verifyTunnel(generation));
  }

  /// Proves the tunnel actually carries traffic before calling it connected.
  ///
  /// Two stages, because they fail for completely different reasons:
  ///
  ///  1. [FlutterV2ray.getConnectedServerDelay] runs inside the core and only
  ///     exercises the *outbound*. It passes whenever the server accepts us,
  ///     regardless of whether the device's packets can reach the core.
  ///  2. A plain HTTP request from this isolate. Our own sockets are not
  ///     protected, so it travels the whole path — TUN → tun2socks → the SOCKS
  ///     inbound → Xray → server. Only this catches a tun2socks that never
  ///     started, which presents as "connected" with a permanently idle
  ///     counter.
  Future<void> _verifyTunnel(int generation) async {
    bool cancelled() =>
        generation != _generation || _state == VpnState.disconnected;

    // Give the core a moment to finish its handshake.
    await Future<void>.delayed(const Duration(milliseconds: 1200));
    if (cancelled()) return;

    var delay = -1;
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        delay = await _v2ray
            .getConnectedServerDelay()
            .timeout(const Duration(seconds: 8));
      } catch (_) {
        delay = -1;
      }
      if (cancelled()) return;
      if (delay >= 0) break;
      await Future<void>.delayed(const Duration(seconds: 2));
    }

    if (cancelled()) return;

    if (delay < 0) {
      await _failVerification(
        'The tunnel came up but the server did not answer. This is almost '
        'always a server-side setting rather than the app.\n\n'
        'If the inbound uses REALITY, check its "dest": it must be a TLS 1.3 '
        'site with a small certificate chain (www.cloudflare.com:443 works, '
        'www.microsoft.com does not).',
      );
      return;
    }

    if (_proxyOnly) {
      // Nothing is routed automatically, so "does the device have internet"
      // says nothing. What matters is that the listener is actually up.
      final open = await _localPortOpen(_socksPort);
      if (cancelled()) return;
      if (!open) {
        await _failVerification(
          'The core started but nothing is listening on 127.0.0.1:$_socksPort. '
          'Another app may be using that port — change it in Settings.',
        );
        return;
      }
      _verifying = false;
      _cancelWatchdog();
      if (!cancelled()) _emitState(VpnState.connected);
      return;
    }

    final flows = await _deviceTrafficFlows();
    if (cancelled()) return;
    if (!flows) {
      await _failVerification(
        'The server is reachable, but this device\'s traffic is not getting '
        'into the tunnel — the VPN reports connected and nothing moves.\n\n'
        'That is the tun2socks helper failing to start. Reinstall the app; if '
        'it persists on a build you made yourself, the APK needs '
        'android.packaging.jniLibs.useLegacyPackaging = true so the helper is '
        'unpacked as a real executable.',
      );
      return;
    }

    // Proven. Only now is this a connection.
    _verifying = false;
    _cancelWatchdog();
    if (!cancelled()) _emitState(VpnState.connected);
  }

  Future<void> _failVerification(String message) async {
    lastFailure = message;
    _starting = false;
    _verifying = false;
    _cancelWatchdog();
    _emitState(VpnState.error);
    // Take the core — and with it Android's "connected" notification — down,
    // so the system never advertises a tunnel the app knows is dead.
    await disconnect();
    // disconnect() lands on `disconnected`; re-assert the error so the UI can
    // explain what happened rather than looking like an idle app.
    _emitState(VpnState.error);
  }

  /// Port the running core was told to listen on, for the proxy-mode check.
  int _socksPort = 10808;

  Future<bool> _localPortOpen(int port) async {
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        final s = await Socket.connect('127.0.0.1', port,
            timeout: const Duration(seconds: 2));
        s.destroy();
        return true;
      } catch (_) {
        await Future<void>.delayed(const Duration(milliseconds: 700));
      }
    }
    return false;
  }

  Future<bool> _deviceTrafficFlows() async {
    // Several tries over ~12s: the first packets often go out while tun2socks
    // is still wiring itself up, and a single lost probe is not an outage.
    for (var attempt = 0; attempt < 3; attempt++) {
      if (_state == VpnState.disconnected) return true;
      if (await Reachability.online(timeout: const Duration(seconds: 4))) {
        return true;
      }
      await Future<void>.delayed(const Duration(seconds: 2));
    }
    return false;
  }

  @override
  Future<void> disconnect() async {
    // Retires whatever attempt is in flight, so its verification cannot come
    // back later and overwrite this stop with a verdict nobody is waiting for.
    _generation++;
    final generation = _generation;
    _emitState(VpnState.disconnecting);
    _starting = false;
    _verifying = false;
    _activeKey = null;
    _cancelWatchdog();
    await _v2ray.stopV2Ray();
    _stats = VpnStats.zero;
    if (!_statsCtrl.isClosed) _statsCtrl.add(_stats);
    _emitState(VpnState.disconnected);
    // Unawaited: the user asked to stop and the UI should say so now. This is
    // the check that it actually happened.
    unawaited(_confirmStopped(generation));
  }

  /// Makes sure the tunnel really went down, and says so again if it did not.
  ///
  /// `stopV2Ray` is a one-way intent to a service in another process — the
  /// plugin runs its core under `android:process=":RunSoLibV2RayDaemon"` — and
  /// it returns as soon as the intent is posted, whatever becomes of it. When
  /// the service came out of that with its TUN device still established,
  /// Android went on showing an active VPN and routing the phone into a tunnel
  /// the app had already forgotten, and the only way out was to connect and
  /// disconnect a second time. The service-side teardown is unconditional now;
  /// this is the belt to that pair of braces, and it costs nothing when the
  /// first stop worked.
  Future<void> _confirmStopped(int generation) async {
    for (var attempt = 0; attempt < 3; attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 800));
      // Somebody asked for a new tunnel in the meantime; this stop is history.
      if (generation != _generation) return;
      if (!await AndroidShortcuts.isTunnelActive()) return;
      if (generation != _generation) return;
      try {
        await _v2ray.stopV2Ray();
      } catch (_) {
        // Nothing useful to do with a failure here — the next pass retries.
      }
    }
  }

  /// Last honest (direct, pre-tunnel) reading per server, keyed like
  /// [_activeKey]. Kept so the number does not jump the moment the tunnel comes
  /// up — see [measureDelay].
  final Map<String, int> _directPings = {};

  @override
  Future<int> measureDelay(ServerConfig server, VpnEngineOptions options) async {
    // A TCP handshake straight to the server, which is exactly what the desktop
    // engine reports. The core's own measurement is a full HTTP request pushed
    // through the tunnel to a third site, so it carries that site's latency and
    // a second traversal on top — the same server read around 90 ms on the
    // desktop app and three times that on the phone.
    //
    // It is only valid while nothing is tunnelling: our sockets are not
    // protected, so once the TUN device is up this probe would travel through
    // the tunnel and measure something else entirely.
    if (_state != VpnState.connected) {
      final direct = await Reachability.tcpPing(server.address, server.port);
      if (direct >= 0) {
        _directPings[_key(server)] = direct;
        return direct;
      }
    }

    try {
      await initialize();
      // Only the *running* tunnel can be measured from inside the core. Asked
      // about any other location it would have answered with the current
      // server's latency, which is how every row in the picker ended up
      // showing the same number.
      if (_state == VpnState.connected && _activeKey == _key(server)) {
        // The reading taken before the tunnel came up describes the same link
        // and is not inflated by the round trip through it. Falling back to the
        // core only when there has never been one.
        final known = _directPings[_key(server)];
        if (known != null) return known;
        return await _v2ray.getConnectedServerDelay();
      }
      if (_state == VpnState.connected) {
        // A second core cannot be started to probe with while one is running,
        // and a direct socket would go through the tunnel.
        return _directPings[_key(server)] ?? -1;
      }
      // The handshake failed. The core reaches the server through whatever
      // transport the config describes, so it can still succeed where a plain
      // socket to the same port does not.
      return await _v2ray.getServerDelay(config: _config(server, options));
    } catch (_) {
      return -1;
    }
  }

  @override
  Future<String> coreVersion() async {
    try {
      await initialize();
      return await _v2ray.getCoreVersion();
    } catch (_) {
      return '';
    }
  }

  @override
  void dispose() {
    _cancelWatchdog();
    _stateCtrl.close();
    _statsCtrl.close();
  }
}
