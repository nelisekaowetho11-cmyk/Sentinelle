import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../../models/models.dart';
import '../singbox_config.dart';
import 'core_manager.dart';
import 'elevation.dart';
import 'process_guard.dart';
import 'reachability.dart';
import 'system_proxy.dart';
import 'vpn_engine.dart';

/// Desktop implementation, powered by sing-box.
///
/// Two modes:
///  * [TunnelMode.proxy] — local SOCKS/HTTP listeners plus the system proxy.
///    No elevation needed.
///  * [TunnelMode.vpn]  — a real TUN device, so every app on the machine is
///    routed whether or not it honours proxy settings. Needs admin/root.
class DesktopVpnEngine implements VpnEngine {
  DesktopVpnEngine();

  static const coreProcessName = 'sing-box';

  final _stateCtrl = StreamController<VpnState>.broadcast();
  final _statsCtrl = StreamController<VpnStats>.broadcast();
  final _guard = ProcessGuard(name: coreProcessName);
  final _mutex = Mutex();

  VpnState _state = VpnState.disconnected;
  VpnStats _stats = VpnStats.zero;

  String? _corePath;
  Timer? _statsTimer;
  DateTime? _connectedAt;
  int _clashPort = 19090;
  int _lastUp = 0;
  int _lastDown = 0;
  final List<String> _log = [];
  bool _shuttingDown = false;

  static const _maxLogLines = 500;

  /// When set, an unexpected core exit leaves the system proxy pointing at the
  /// now-dead local port instead of restoring the direct settings.
  ///
  /// That is the desktop kill switch in proxy mode: applications keep sending
  /// their traffic to a listener that is gone and fail, rather than silently
  /// falling back to the open connection the moment the tunnel dies. A
  /// deliberate [disconnect] always restores the proxy.
  bool killSwitch = true;

  /// True while the proxy is being held closed by [killSwitch].
  bool get holdingClosed => _holdingClosed;
  bool _holdingClosed = false;

  /// Why the last attempt failed, in words, with the core's own output behind
  /// it.
  ///
  /// Without this a core that started and then died reached the UI as the bare
  /// word "Error": the exception path set a message, but an exit *after* a
  /// successful connect went through [onExit], which had nothing to say.
  @override
  String? lastFailure;

  /// The tail of the core log that went with [lastFailure], kept separately so
  /// the UI can show the diagnosis up front and the raw output on demand.
  String lastFailureLog = '';

  void _fail(String message, {String? log}) {
    lastFailure = message;
    lastFailureLog = log ?? _logTail();
  }

  /// The last few lines of core output — enough to diagnose, short enough to
  /// paste into a message.
  String _logTail([int lines = 20]) =>
      _log.reversed.take(lines).toList().reversed.join('\n');

  /// Turns a core exit into something a person can act on.
  ///
  /// sing-box says why it is unhappy, but it says it in one line among many,
  /// and it says it and quits. Matching the handful of failures that actually
  /// happen is worth far more than showing an exit code.
  static String diagnose(int exitCode, String tail, TunnelMode mode) {
    final t = tail.toLowerCase();

    if (t.contains('address already in use') ||
        t.contains('only one usage of each socket address')) {
      return 'Another program is already using one of the local ports. '
          'Change the SOCKS/HTTP ports in Settings, or close whatever else is '
          'listening — often a second VPN client.';
    }
    if (t.contains('operation not permitted') ||
        t.contains('access is denied') ||
        t.contains('permission denied')) {
      return mode == TunnelMode.vpn
          ? 'VPN mode needs administrator rights. ${Elevation.manualInstruction} '
              'Or switch to Proxy mode in Settings.'
          : 'The core was denied permission to start. Antivirus or a security '
              'policy is the usual cause.';
    }
    if (t.contains('reality') || t.contains('handshake')) {
      return 'The server rejected the handshake. For REALITY inbounds this is '
          'almost always the server\'s "dest": it must be a TLS 1.3 site with '
          'a small certificate chain (www.cloudflare.com:443 works, '
          'www.microsoft.com does not).';
    }
    if (t.contains('no such host') ||
        t.contains('lookup') && t.contains('failed')) {
      return 'The server address could not be resolved. Check the address, or '
          'try a different location.';
    }
    if (t.contains('connection refused') ||
        t.contains('i/o timeout') ||
        t.contains('timeout')) {
      return 'The server did not answer. It may be down, or blocked from this '
          'network — try another location.';
    }
    if (t.contains('decode config') ||
        t.contains('parse config') ||
        t.contains('invalid config') ||
        t.contains('unknown field')) {
      return 'The core rejected the generated configuration. This is a bug in '
          'the app or an option the installed core is too old for — the log '
          'below names the field.';
    }
    if (t.contains('missing tun') || t.contains('wintun') || t.contains('utun')) {
      // macOS has no driver to install: utun is in the kernel and the only
      // thing between the core and a working device is root.
      return Platform.isMacOS
          ? 'The utun device could not be created — that needs root. '
              '${Elevation.manualInstruction} Or switch to Proxy mode in '
              'Settings.'
          : 'The TUN driver could not be opened. Reinstall the app, or switch '
              'to Proxy mode in Settings.';
    }
    return 'The tunnel stopped unexpectedly (exit code $exitCode).';
  }

  @override
  Stream<VpnState> get stateStream => _stateCtrl.stream;
  @override
  Stream<VpnStats> get statsStream => _statsCtrl.stream;
  @override
  VpnState get state => _state;
  @override
  VpnStats get stats => _stats;

  List<String> get log => List.unmodifiable(_log);

  void _emitState(VpnState s) {
    if (_state == s) return;
    _state = s;
    if (!_stateCtrl.isClosed) _stateCtrl.add(s);
  }

  void _addLog(String line) {
    if (line.trim().isEmpty) return;
    _log.add(line.trimRight());
    if (_log.length > _maxLogLines) {
      _log.removeRange(0, _log.length - _maxLogLines);
    }
  }

  /// True when the previous run went down with a tunnel still up.
  ///
  /// Set by [sweepOrphans] so the UI can say what happened rather than leaving
  /// the user wondering why their proxy settings changed.
  static bool lastRunCrashed = false;

  /// Clears anything a previous run left behind: stray cores, every per-app
  /// route they were carrying, and a system proxy still pointing at a listener
  /// that died with them.
  ///
  /// This is the guard against a crash leaving tunnels running: the cores are
  /// separate processes and outlive the window quite happily, so nothing but
  /// an explicit sweep brings them down.
  static Future<void> sweepOrphans() async {
    lastRunCrashed = await ProcessGuard.consumeCrashMarker();
    await ProcessGuard.sweepOrphans(const ['sing-box', 'xray']);
    await SystemProxy.restoreLeftovers();
  }

  @override
  Future<void> initialize() async {
    _corePath ??= await CoreManager.resolve(CoreKind.singbox, '');
  }

  @override
  Future<bool> isReady() async => _corePath != null;

  @override
  Future<bool> requestPermission() async => true;

  /// Resolves the core, downloading it if it is not installed yet.
  Future<String> ensureCore(
    String explicitPath, {
    void Function(double, String)? onProgress,
  }) async {
    final found = await CoreManager.resolve(CoreKind.singbox, explicitPath);
    if (found != null) {
      _corePath = found;
      return found;
    }
    final path = await CoreManager.download(CoreKind.singbox, onProgress: onProgress);
    _corePath = path;
    return path;
  }

  Future<File> _writeConfig(ServerConfig server, VpnEngineOptions o) async {
    final dir = await getApplicationSupportDirectory();
    final file = File('${dir.path}${Platform.pathSeparator}singbox-config.json');
    _clashPort = _pickFreePort(o, 19090);
    final json = SingBoxConfigBuilder(
      mode: o.mode,
      socksPort: o.socksPort,
      httpPort: o.httpPort,
      dnsServers: o.dnsServers,
      bypassLan: o.bypassLan,
      blockAds: o.blockAds,
      splitMode: o.splitMode,
      splitApps: o.splitApps,
      forceTunnel: o.forceTunnel,
      forceDirect: o.forceDirect,
      clashApiPort: _clashPort,
      dnsGuard: o.dnsGuard,
      ipv6Guard: o.ipv6Guard,
      webRtcGuard: o.webRtcGuard,
      lanGuard: o.lanGuard,
      quicGuard: o.quicGuard,
      appRoutes: o.appRoutes,
    ).buildJson(server);
    await file.writeAsString(json, flush: true);
    return file;
  }

  int _pickFreePort(VpnEngineOptions o, int start) {
    var p = start;
    while (p == o.socksPort || p == o.httpPort) {
      p++;
    }
    return p;
  }

  /// Bumped whenever an attempt is started, superseded or cancelled.
  ///
  /// Cancelling cannot simply take the mutex: a connect holds it for as long as
  /// the whole sequence takes — up to twelve seconds waiting for the listener,
  /// then three reachability probes — so a queued "stop" would sit there doing
  /// nothing for the entire time the user was trying to abort. Instead the
  /// generation is raised and the core is killed from outside the lock, and
  /// the running attempt notices at its next checkpoint and unwinds itself.
  int _generation = 0;

  /// Aborts whatever attempt is in flight, without waiting for it.
  ///
  /// Killing the process is what makes the abort quick rather than polite:
  /// every wait in [_connect] gives up the moment the guard stops running.
  Future<void> _abortInFlight() async {
    _generation++;
    if (_guard.isRunning) await _guard.stop();
  }

  @override
  Future<void> connect(ServerConfig server, VpnEngineOptions options) async {
    // A new destination supersedes the old attempt for the same reason a
    // cancel does — otherwise switching server mid-handshake waits out the
    // first one's timeouts before starting the second.
    await _abortInFlight();
    return _mutex.run(() => _connect(server, options));
  }

  Future<void> _connect(ServerConfig server, VpnEngineOptions options) async {
    final generation = ++_generation;
    bool cancelled() => generation != _generation;

    /// Unwinds a cancelled attempt as an ordinary stop.
    ///
    /// Not an error: the user asked for this, and painting a red failure panel
    /// at someone who pressed cancel is telling them off for it.
    Future<void> abandon() async {
      await _stopCore(restoreProxy: true);
      lastFailure = null;
      lastFailureLog = '';
      _emitState(VpnState.disconnected);
    }

    // Whatever was running before goes down first — this is what stopped the
    // app from piling up cores when switching servers. While the kill switch
    // holds the proxy closed, restoring it here would open a leak for exactly
    // as long as the reconnect takes.
    await _stopCore(restoreProxy: !_holdingClosed);
    if (cancelled()) return abandon();

    if (!SingBoxConfigBuilder.supports(server)) {
      _fail('${server.protocol.toUpperCase()} over '
          '${server.network.toUpperCase()} is not supported by the desktop '
          'core. Pick another location.');
      _emitState(VpnState.error);
      throw Exception(
          '${server.protocol.toUpperCase()} over ${server.network.toUpperCase()} '
          'is not supported by the desktop core. Pick another location.');
    }

    _emitState(VpnState.connecting);
    _log.clear();
    lastFailure = null;
    lastFailureLog = '';

    try {
      final core = await ensureCore(options.corePath);
      final cfg = await _writeConfig(server, options);
      final workDir = File(core).parent.path;

      _addLog('[app] ${options.mode == TunnelMode.vpn ? 'VPN (TUN)' : 'Proxy'} '
          'mode · ${server.name}');

      await _guard.run(
        core,
        ['run', '-c', cfg.path, '-D', workDir],
        workingDirectory: workDir,
        onOutput: _addLog,
        onExit: (code) {
          if (_shuttingDown) return;
          if (_state == VpnState.connected || _state == VpnState.connecting) {
            _addLog('[app] core exited with code $code');
            if (code != 0 || _state == VpnState.connected) {
              final tail = _logTail();
              _fail(diagnose(code, tail, options.mode), log: tail);
            }
            // The one path where traffic would otherwise leak: a tunnel that
            // was actually carrying traffic died without anyone asking it to.
            // A core that exited during startup never carried anything, and
            // holding the proxy shut for it just takes the machine offline.
            final hold = killSwitch &&
                _state == VpnState.connected &&
                options.mode == TunnelMode.proxy &&
                options.systemProxy;
            _holdingClosed = hold;
            if (hold) _addLog('[app] kill switch: holding the system proxy');
            unawaited(_stopCore(restoreProxy: !hold).then((_) {
              _emitState(code == 0 ? VpnState.disconnected : VpnState.error);
            }));
          }
        },
      );

      if (cancelled()) return abandon();

      final up = await _waitForPort('127.0.0.1', options.socksPort,
          timeout: const Duration(seconds: 12));
      // Checked before the failure branch: a cancel kills the core, so the
      // listener never appears — and reporting that as "the core did not
      // start" would blame the app for doing what it was told.
      if (cancelled()) return abandon();
      if (!up) {
        final tail = _log.reversed.take(8).toList().reversed.join('\n');
        await _stopCore(restoreProxy: true);
        _emitState(VpnState.error);
        throw Exception(_startupFailureMessage(options, tail));
      }

      // The HTTP listener is the one the system proxy is pointed at, so it has
      // to be up too. Only the SOCKS port was ever checked, which meant a
      // clashing HTTP port produced a "connected" tunnel aimed at a dead
      // listener.
      if (options.httpPort != options.socksPort) {
        final httpUp = await _waitForPort('127.0.0.1', options.httpPort,
            timeout: const Duration(seconds: 6));
        if (cancelled()) return abandon();
        if (!httpUp) {
          final tail = _logTail(8);
          await _stopCore(restoreProxy: true);
          _emitState(VpnState.error);
          throw Exception(
              'The core is listening on ${options.socksPort} but not on '
              '${options.httpPort}, which is the port the system proxy uses. '
              'Something else is holding that port — change the local HTTP '
              'port in Settings.\n$tail');
        }
      }

      if (options.mode == TunnelMode.proxy && options.systemProxy) {
        final ok = await SystemProxy.enable('127.0.0.1', options.httpPort);
        if (cancelled()) return abandon();
        if (!ok) {
          await _stopCore(restoreProxy: true);
          _emitState(VpnState.error);
          throw Exception(
              'The tunnel is up, but the system proxy could not be set — so '
              'nothing on this machine is actually being routed through it. '
              'A policy on a managed device is the usual cause.\n\n'
              'Switch to VPN mode in Settings, or point apps at '
              '127.0.0.1:${options.httpPort} yourself.');
        }
      }

      // An open port only says the core started. sing-box binds its inbounds
      // before it has ever spoken to the server, so a refused handshake or an
      // unreachable server looks exactly like success — which is how proxy
      // mode came to report "connected" while carrying nothing.
      if (options.mode == TunnelMode.proxy) {
        final carries = await _proxyCarriesTraffic(options.httpPort);
        if (cancelled()) return abandon();
        if (!carries) {
          final tail = _logTail();
          _fail(
            'The local proxy is listening, but nothing gets through it. The '
            'core started and the server did not complete the connection.\n\n'
            'If the inbound uses REALITY, check its "dest": it must be a TLS '
            '1.3 site with a small certificate chain '
            '(www.cloudflare.com:443 works, www.microsoft.com does not).',
            log: tail,
          );
          await _stopCore(restoreProxy: true);
          _emitState(VpnState.error);
          throw Exception(lastFailure);
        }
      }

      if (cancelled()) return abandon();

      // From here a crash would leave a core running, so say so on disk.
      unawaited(ProcessGuard.markSessionOpen());
      _holdingClosed = false;
      _connectedAt = DateTime.now();
      _lastUp = 0;
      _lastDown = 0;
      _startStatsPolling();
      _emitState(VpnState.connected);
    } catch (e) {
      // A cancel tears the core down underneath the sequence, so whatever it
      // was waiting on throws. That is the abort working, not a failure.
      if (cancelled()) {
        await abandon();
        return;
      }
      _addLog('[app] $e');
      lastFailure ??= '$e'.replaceFirst('Exception: ', '');
      if (lastFailureLog.isEmpty) {
        lastFailureLog = _logTail();
      }
      await _stopCore(restoreProxy: true);
      _emitState(VpnState.error);
      rethrow;
    }
  }

  String _startupFailureMessage(VpnEngineOptions options, String tail) {
    final logText = tail.toLowerCase();
    if (options.mode == TunnelMode.vpn &&
        (logText.contains('operation not permitted') ||
            logText.contains('access is denied') ||
            logText.contains('administrator') ||
            logText.contains('permission denied'))) {
      return 'VPN mode needs administrator rights. '
          '${Elevation.manualInstruction} '
          'Or switch to Proxy mode in Settings.\n$tail';
    }
    if (logText.contains('address already in use') ||
        logText.contains('only one usage of each socket address')) {
      return 'Port ${options.socksPort} is already in use. Change the local '
          'ports in Settings.\n$tail';
    }
    return 'The core did not start listening on port ${options.socksPort}.\n$tail';
  }

  /// Proves the local proxy reaches the internet, not merely that it is bound.
  ///
  /// Several tries: the first request often goes out while the core is still
  /// finishing its handshake, and one lost probe is not an outage. Two
  /// different endpoints are tried per attempt (see [Reachability]) so a single
  /// blocked host cannot condemn a working tunnel.
  Future<bool> _proxyCarriesTraffic(int port) async {
    for (var attempt = 0; attempt < 3; attempt++) {
      if (!_guard.isRunning) return false;
      if (await Reachability.online(
        timeout: const Duration(seconds: 6),
        via: '127.0.0.1:$port',
      )) {
        return true;
      }
      await Future<void>.delayed(const Duration(milliseconds: 1200));
    }
    return false;
  }

  Future<bool> _waitForPort(String host, int port,
      {required Duration timeout}) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (!_guard.isRunning) return false;
      try {
        final s = await Socket.connect(host, port,
            timeout: const Duration(milliseconds: 400));
        s.destroy();
        return true;
      } catch (_) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
    }
    return false;
  }

  // ── Stats via the Clash API sing-box exposes ───────────────────────────────

  void _startStatsPolling() {
    _statsTimer?.cancel();
    _statsTimer = Timer.periodic(const Duration(seconds: 1), (_) => _pollStats());
  }

  Future<void> _pollStats() async {
    if (!_guard.isRunning) return;
    var up = _lastUp;
    var down = _lastDown;
    try {
      final r = await http
          .get(Uri.parse('http://127.0.0.1:$_clashPort/connections'))
          .timeout(const Duration(milliseconds: 900));
      if (r.statusCode == 200) {
        final j = jsonDecode(r.body) as Map<String, dynamic>;
        up = (j['uploadTotal'] as num?)?.toInt() ?? up;
        down = (j['downloadTotal'] as num?)?.toInt() ?? down;
      }
    } catch (_) {
      // Keep the previous totals; a single failed poll is not an outage.
    }

    final upSpeed = (up - _lastUp).clamp(0, 1 << 62);
    final downSpeed = (down - _lastDown).clamp(0, 1 << 62);
    _lastUp = up;
    _lastDown = down;

    _stats = VpnStats(
      uploadSpeed: upSpeed,
      downloadSpeed: downSpeed,
      uploadTotal: up,
      downloadTotal: down,
      duration: _connectedAt == null
          ? Duration.zero
          : DateTime.now().difference(_connectedAt!),
    );
    if (!_statsCtrl.isClosed) _statsCtrl.add(_stats);
  }

  // ── Teardown ───────────────────────────────────────────────────────────────

  Future<void> _stopCore({required bool restoreProxy}) async {
    _statsTimer?.cancel();
    _statsTimer = null;
    _connectedAt = null;
    if (restoreProxy) await SystemProxy.disable();
    await _guard.stop();
    await ProcessGuard.markSessionClosed();
  }

  /// Deliberate teardown always opens the machine back up — the kill switch
  /// guards against the tunnel dying, not against the user leaving.
  ///
  /// The abort happens *before* the lock is asked for, so pressing stop during
  /// a handshake takes effect immediately instead of queueing behind the
  /// attempt it is trying to stop.
  @override
  Future<void> disconnect() async {
    await _abortInFlight();
    return _mutex.run(() async {
      _holdingClosed = false;
      if (!_guard.isRunning && _state == VpnState.disconnected) {
        await SystemProxy.disable();
        return;
      }
      _emitState(VpnState.disconnecting);
      await _stopCore(restoreProxy: true);
      _stats = VpnStats.zero;
      if (!_statsCtrl.isClosed) _statsCtrl.add(_stats);
      _emitState(VpnState.disconnected);
    });
  }

  /// Called on app exit — synchronous enough to finish before the window dies.
  Future<void> shutdown() async {
    _shuttingDown = true;
    await _stopCore(restoreProxy: true);
  }

  @override
  Future<int> measureDelay(ServerConfig server, VpnEngineOptions options) async {
    final sw = Stopwatch()..start();
    try {
      final s = await Socket.connect(server.address, server.port,
          timeout: const Duration(seconds: 5));
      sw.stop();
      s.destroy();
      return sw.elapsedMilliseconds;
    } catch (_) {
      return -1;
    }
  }

  @override
  Future<String> coreVersion() async {
    final core = _corePath ?? await CoreManager.resolve(CoreKind.singbox, '');
    if (core == null) return '';
    return CoreManager.version(core);
  }

  @override
  void dispose() {
    _shuttingDown = true;
    unawaited(_stopCore(restoreProxy: true));
    _stateCtrl.close();
    _statsCtrl.close();
  }
}
