import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'wininet_proxy.dart';

/// Points the OS at the local HTTP proxy the core exposes, and — importantly —
/// puts the previous settings back afterwards.
///
/// The previous state is written to disk before anything is changed, so a
/// crash or a killed process cannot leave the machine pointing at a proxy that
/// is no longer listening. [restoreLeftovers] replays that file at startup.
class SystemProxy {
  static const _bypass =
      'localhost;127.*;10.*;172.16.*;172.17.*;172.18.*;172.19.*;172.20.*;'
      '172.21.*;172.22.*;172.23.*;172.24.*;172.25.*;172.26.*;172.27.*;'
      '172.28.*;172.29.*;172.30.*;172.31.*;192.168.*;<local>';

  static bool _applied = false;
  static bool get applied => _applied;

  static Future<File> _stateFile() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}${Platform.pathSeparator}system-proxy-backup.json');
  }

  // ── Public API ─────────────────────────────────────────────────────────────

  /// Returns false when the machine was *not* actually pointed at the proxy.
  ///
  /// Worth knowing rather than swallowing: in proxy mode the system proxy is
  /// the only thing routing anything, so a silent failure here is a tunnel
  /// that reports connected and carries nobody's traffic.
  static Future<bool> enable(String host, int port) async {
    try {
      if (Platform.isWindows) {
        await _saveState(await _windowsRead());
        // Both places, deliberately: WinINet's connection blob is what most
        // software actually follows, but plenty of tools read the registry
        // DWORD directly and the two do not update each other.
        WinInetProxy.enable('$host:$port', _bypass);
        await _windowsApply(
            enabled: true, server: '$host:$port', bypass: _bypass);
        _applied = await _windowsVerify('$host:$port');
        return _applied;
      } else if (Platform.isMacOS) {
        await _saveState(await _macosRead());
        await _macosEnable(host, port);
      } else if (Platform.isLinux) {
        await _saveState(await _linuxRead());
        await _linuxEnable(host, port);
      } else {
        return false;
      }
      _applied = true;
      return true;
    } catch (_) {
      // Never let a proxy problem block the tunnel itself.
      return false;
    }
  }

  /// Reads the settings back. A write that returned success and did not stick
  /// is the failure mode worth catching — group policy pins these values on
  /// managed machines, and `reg add` reports no error when it happens.
  static Future<bool> _windowsVerify(String server) async {
    final now = await _windowsRead();
    if (now == null) return false;
    final enabled = ((now['ProxyEnable'] as String?) ?? '0x0').endsWith('1');
    final current = (now['ProxyServer'] as String?) ?? '';
    return enabled && current.toLowerCase() == server.toLowerCase();
  }

  static Future<void> disable() async {
    try {
      final saved = await _readState();
      if (Platform.isWindows) {
        await _windowsRestore(saved);
      } else if (Platform.isMacOS) {
        await _macosRestore(saved);
      } else if (Platform.isLinux) {
        await _linuxRestore(saved);
      }
      await _clearState();
    } catch (_) {
      // ignore
    }
    _applied = false;
  }

  /// Called at startup: if a previous run died while the proxy was ours, put
  /// the machine back the way we found it.
  static Future<void> restoreLeftovers() async {
    try {
      final saved = await _readState();
      if (saved == null) return;
      if (Platform.isWindows) {
        await _windowsRestore(saved);
      } else if (Platform.isMacOS) {
        await _macosRestore(saved);
      } else if (Platform.isLinux) {
        await _linuxRestore(saved);
      }
      await _clearState();
    } catch (_) {
      // ignore
    }
  }

  // ── Backup file ────────────────────────────────────────────────────────────

  /// Never overwrites a backup that is already there.
  ///
  /// The kill switch deliberately leaves our own settings in place across a
  /// reconnect, and a second [enable] would then record *those* as "what the
  /// user had" — so the eventual restore would put the machine back to a proxy
  /// that is ours and about to die with us. A backup is cleared on every
  /// successful restore, so the only file that can be found here is one that
  /// still describes the machine as we found it.
  static Future<void> _saveState(Map<String, dynamic>? state) async {
    if (state == null) return;
    try {
      final f = await _stateFile();
      if (await f.exists()) return;
      await f.writeAsString(jsonEncode(state), flush: true);
    } catch (_) {}
  }

  static Future<Map<String, dynamic>?> _readState() async {
    try {
      final f = await _stateFile();
      if (!await f.exists()) return null;
      return jsonDecode(await f.readAsString()) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  static Future<void> _clearState() async {
    try {
      final f = await _stateFile();
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  // ── Windows ────────────────────────────────────────────────────────────────
  static const _regPath =
      r'HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings';

  static Future<Map<String, dynamic>?> _windowsRead() async {
    Future<String?> read(String name) async {
      try {
        final r = await Process.run('reg', ['query', _regPath, '/v', name]);
        if (r.exitCode != 0) return null;
        final line = (r.stdout as String)
            .split('\n')
            .firstWhere((l) => l.contains(name), orElse: () => '');
        final parts = line.trim().split(RegExp(r'\s{2,}'));
        return parts.length >= 3 ? parts.last.trim() : null;
      } catch (_) {
        return null;
      }
    }

    return {
      'platform': 'windows',
      'ProxyEnable': await read('ProxyEnable') ?? '0x0',
      'ProxyServer': await read('ProxyServer'),
      'ProxyOverride': await read('ProxyOverride'),
    };
  }

  static Future<void> _windowsApply({
    required bool enabled,
    String? server,
    String? bypass,
  }) async {
    await Process.run('reg', [
      'add', _regPath, '/v', 'ProxyEnable', '/t', 'REG_DWORD',
      '/d', enabled ? '1' : '0', '/f',
    ]);
    if (server != null) {
      await Process.run('reg', [
        'add', _regPath, '/v', 'ProxyServer', '/t', 'REG_SZ', '/d', server, '/f',
      ]);
    }
    if (bypass != null) {
      await Process.run('reg', [
        'add', _regPath, '/v', 'ProxyOverride', '/t', 'REG_SZ', '/d', bypass, '/f',
      ]);
    }
    _refreshWinInet();
  }

  static Future<void> _windowsDelete(String name) async {
    await Process.run('reg', ['delete', _regPath, '/v', name, '/f']);
  }

  static Future<void> _windowsRestore(Map<String, dynamic>? saved) async {
    final wasEnabled = (saved?['ProxyEnable'] as String?) ?? '0x0';
    final prevServer = saved?['ProxyServer'] as String?;
    final prevOverride = saved?['ProxyOverride'] as String?;

    final enabled = wasEnabled.endsWith('1');

    // Clear it through WinINet first so the connection blob is updated too —
    // a stale blob is why a disabled proxy could still be picked up long after
    // ProxyEnable went back to 0.
    if (!enabled) {
      WinInetProxy.disable();
    } else if (prevServer != null && prevServer.isNotEmpty) {
      WinInetProxy.enable(prevServer, prevOverride ?? '<local>');
    }

    await Process.run('reg', [
      'add', _regPath, '/v', 'ProxyEnable', '/t', 'REG_DWORD',
      '/d', enabled ? '1' : '0', '/f',
    ]);

    // Leaving a dead 127.0.0.1 proxy behind confuses anything that reads the
    // value without checking ProxyEnable, so put back exactly what was there —
    // including removing the key if it did not exist before.
    if (prevServer == null || prevServer.isEmpty) {
      await _windowsDelete('ProxyServer');
    } else {
      await Process.run('reg', [
        'add', _regPath, '/v', 'ProxyServer', '/t', 'REG_SZ', '/d', prevServer, '/f',
      ]);
    }
    if (prevOverride == null || prevOverride.isEmpty) {
      await _windowsDelete('ProxyOverride');
    } else {
      await Process.run('reg', [
        'add', _regPath, '/v', 'ProxyOverride', '/t', 'REG_SZ',
        '/d', prevOverride, '/f',
      ]);
    }

    _refreshWinInet();
  }

  /// Tell WinINet the settings changed — without this, already-running apps
  /// keep using the old configuration until they restart.
  static void _refreshWinInet() {
    if (!Platform.isWindows) return;
    try {
      final wininet = DynamicLibrary.open('wininet.dll');
      final setOption = wininet.lookupFunction<
          Int32 Function(Pointer<Void>, Uint32, Pointer<Void>, Uint32),
          int Function(Pointer<Void>, int, Pointer<Void>, int)>(
        'InternetSetOptionW',
      );
      const internetOptionSettingsChanged = 39;
      const internetOptionRefresh = 37;
      setOption(nullptr, internetOptionSettingsChanged, nullptr, 0);
      setOption(nullptr, internetOptionRefresh, nullptr, 0);
    } catch (_) {
      // The registry write alone is enough for most software.
    }
  }

  // ── macOS ──────────────────────────────────────────────────────────────────
  static Future<List<String>> _macServices() async {
    final r = await Process.run('networksetup', ['-listallnetworkservices']);
    return (r.stdout as String)
        .split('\n')
        .skip(1)
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty && !s.startsWith('*'))
        .toList();
  }

  /// What each network service had before we touched it.
  ///
  /// Windows and Linux have always recorded this; macOS recorded the bare word
  /// "macos" and then simply switched the proxy *off* on disconnect. On a
  /// machine with a proxy of its own — managed and corporate Macs, mostly —
  /// that took the user's setting away and never gave it back.
  static Future<Map<String, dynamic>> _macosRead() async {
    final services = <String, dynamic>{};
    for (final s in await _macServices()) {
      services[s] = {
        'web': await _macReadOne('-getwebproxy', s),
        'secure': await _macReadOne('-getsecurewebproxy', s),
      };
    }
    return {'platform': 'macos', 'services': services};
  }

  static Future<Map<String, String>> _macReadOne(
      String verb, String service) async {
    try {
      final r = await Process.run('networksetup', [verb, service]);
      return parseProxyOutput(r.stdout as String);
    } catch (_) {
      return const {};
    }
  }

  /// Turns `networksetup -getwebproxy` output into a map.
  ///
  /// ```
  /// Enabled: Yes
  /// Server: proxy.corp.example
  /// Port: 8080
  /// ```
  static Map<String, String> parseProxyOutput(String stdout) {
    final out = <String, String>{};
    for (final line in stdout.split('\n')) {
      final i = line.indexOf(':');
      if (i <= 0) continue;
      out[line.substring(0, i).trim().toLowerCase()] =
          line.substring(i + 1).trim();
    }
    return out;
  }

  static Future<void> _macosRestore(Map<String, dynamic>? saved) async {
    final services = (saved?['services'] as Map?)?.cast<String, dynamic>();
    if (services == null || services.isEmpty) {
      // Nothing recorded — a backup written by an older build, or a read that
      // failed. Off is the safe answer: it is what the machine looked like for
      // everyone who had no proxy of their own, which is nearly everyone.
      await _macosDisable();
      return;
    }
    for (final entry in services.entries) {
      final state = (entry.value as Map).cast<String, dynamic>();
      await _macRestoreOne(entry.key, web: true, was: state['web']);
      await _macRestoreOne(entry.key, web: false, was: state['secure']);
    }
  }

  static Future<void> _macRestoreOne(String service,
      {required bool web, Object? was}) async {
    final setProxy = web ? '-setwebproxy' : '-setsecurewebproxy';
    final setState = web ? '-setwebproxystate' : '-setsecurewebproxystate';
    final prev = (was as Map?)?.cast<String, dynamic>() ?? const {};
    final enabled = (prev['enabled'] as String?)?.toLowerCase() == 'yes';
    final server = (prev['server'] as String?) ?? '';
    final port = (prev['port'] as String?) ?? '';

    if (!enabled || server.isEmpty || port.isEmpty || port == '0') {
      await Process.run('networksetup', [setState, service, 'off']);
      return;
    }
    await Process.run('networksetup', [setProxy, service, server, port]);
    await Process.run('networksetup', [setState, service, 'on']);
  }

  static Future<void> _macosEnable(String host, int port) async {
    for (final s in await _macServices()) {
      await Process.run('networksetup', ['-setwebproxy', s, host, '$port']);
      await Process.run('networksetup', ['-setsecurewebproxy', s, host, '$port']);
      await Process.run('networksetup', ['-setwebproxystate', s, 'on']);
      await Process.run('networksetup', ['-setsecurewebproxystate', s, 'on']);
    }
  }

  static Future<void> _macosDisable() async {
    for (final s in await _macServices()) {
      await Process.run('networksetup', ['-setwebproxystate', s, 'off']);
      await Process.run('networksetup', ['-setsecurewebproxystate', s, 'off']);
    }
  }

  // ── Linux (GNOME / GTK apps) ───────────────────────────────────────────────
  static Future<Map<String, dynamic>?> _linuxRead() async {
    try {
      final r = await Process.run(
          'gsettings', ['get', 'org.gnome.system.proxy', 'mode']);
      return {
        'platform': 'linux',
        'mode': (r.stdout as String).trim().replaceAll("'", ''),
      };
    } catch (_) {
      return {'platform': 'linux', 'mode': 'none'};
    }
  }

  static Future<void> _linuxEnable(String host, int port) async {
    Future<void> gs(List<String> args) => Process.run('gsettings', args);
    await gs(['set', 'org.gnome.system.proxy', 'mode', 'manual']);
    for (final scheme in ['http', 'https']) {
      await gs(['set', 'org.gnome.system.proxy.$scheme', 'host', host]);
      await gs(['set', 'org.gnome.system.proxy.$scheme', 'port', '$port']);
    }
    await gs(['set', 'org.gnome.system.proxy.socks', 'host', host]);
    await gs([
      'set', 'org.gnome.system.proxy', 'ignore-hosts',
      "['localhost', '127.0.0.0/8', '10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16']",
    ]);
  }

  static Future<void> _linuxRestore(Map<String, dynamic>? saved) async {
    final mode = (saved?['mode'] as String?) ?? 'none';
    await Process.run('gsettings', ['set', 'org.gnome.system.proxy', 'mode', mode]);
  }
}
