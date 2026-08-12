import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

/// A candidate application for per-app routing.
class AppEntry {
  const AppEntry({required this.executable, this.title, this.icon, this.system = false});

  /// What the core matches on: `chrome.exe` on Windows, `firefox` elsewhere,
  /// a package name on Android.
  final String executable;

  /// Window title or friendly name, when we know one.
  final String? title;

  /// Decoded PNG bytes for the app icon (Android only).
  final Uint8List? icon;

  /// True for Android system apps, so the picker can group them.
  final bool system;

  String get label => title == null || title!.isEmpty ? executable : title!;
}

/// Lists applications the user can pick for split tunnelling.
///
/// sing-box matches on the *executable name*, so the running-process list is
/// exactly the right source on desktop — it is also the only list that needs no
/// extra permissions.
class AppList {
  /// Executables that are part of the OS and would only confuse the list.
  static const _noise = {
    'system', 'system idle process', 'registry', 'memory compression',
    'smss.exe', 'csrss.exe', 'wininit.exe', 'winlogon.exe', 'services.exe',
    'lsass.exe', 'svchost.exe', 'fontdrvhost.exe', 'dwm.exe', 'sihost.exe',
    'taskhostw.exe', 'ctfmon.exe', 'conhost.exe', 'dllhost.exe', 'runtimebroker.exe',
    'searchindexer.exe', 'searchhost.exe', 'shellexperiencehost.exe',
    'startmenuexperiencehost.exe', 'textinputhost.exe', 'audiodg.exe',
    'wudfhost.exe', 'spoolsv.exe', 'taskmgr.exe', 'explorer.exe',
    'applicationframehost.exe', 'backgroundtaskhost.exe', 'wmiprvse.exe',
    'securityhealthservice.exe', 'securityhealthsystray.exe', 'sppsvc.exe',
    'lsaiso.exe', 'wlanext.exe', 'sedsvc.exe', 'msmpeng.exe', 'nissrv.exe',
    'sing-box.exe', 'xray.exe',
  };

  static const _channel = MethodChannel('app.veil/installed_apps');

  static bool get supported =>
      Platform.isAndroid ||
      Platform.isWindows ||
      Platform.isLinux ||
      Platform.isMacOS;

  /// On Android this is the full installed-app list; on desktop it is the set
  /// of running executables, which is what the core actually matches on.
  static bool get listsInstalledApps => Platform.isAndroid;

  /// Applications the user can pick.
  static Future<List<AppEntry>> running() async {
    try {
      if (Platform.isAndroid) return await _android();
      if (Platform.isWindows) return await _windows();
      if (Platform.isMacOS || Platform.isLinux) return await _posix();
    } catch (_) {
      // fall through
    }
    return const [];
  }

  /// Installed apps that hold the INTERNET permission, with their icons.
  static Future<List<AppEntry>> _android() async {
    final raw = await _channel.invokeListMethod<Object?>('list', {'icons': true});
    if (raw == null) return const [];
    final apps = <AppEntry>[];
    for (final item in raw) {
      final m = Map<String, dynamic>.from(item as Map);
      final iconB64 = m['icon'] as String?;
      apps.add(AppEntry(
        executable: (m['package'] ?? '') as String,
        title: (m['name'] ?? '') as String,
        system: (m['system'] ?? false) as bool,
        icon: iconB64 == null || iconB64.isEmpty
            ? null
            : base64Decode(iconB64),
      ));
    }
    return apps;
  }

  static Future<List<AppEntry>> _windows() async {
    // CSV keeps parsing simple and survives spaces in image names.
    final r = await Process.run('tasklist', ['/FO', 'CSV', '/NH'])
        .timeout(const Duration(seconds: 10));
    final seen = <String, AppEntry>{};
    for (final line in (r.stdout as String).split('\n')) {
      final cells = _csvCells(line);
      if (cells.isEmpty) continue;
      final exe = cells.first.trim();
      if (exe.isEmpty) continue;
      final key = exe.toLowerCase();
      if (_noise.contains(key)) continue;
      seen.putIfAbsent(key, () => AppEntry(executable: exe));
    }
    final list = seen.values.toList()
      ..sort((a, b) =>
          a.executable.toLowerCase().compareTo(b.executable.toLowerCase()));
    return list;
  }

  static Future<List<AppEntry>> _posix() async {
    final r = await Process.run('ps', ['-eo', 'comm'])
        .timeout(const Duration(seconds: 10));
    final seen = <String, AppEntry>{};
    for (final raw in (r.stdout as String).split('\n').skip(1)) {
      final name = raw.trim().split('/').last;
      if (name.isEmpty || name.startsWith('[')) continue;
      final key = name.toLowerCase();
      if (_noise.contains(key)) continue;
      seen.putIfAbsent(key, () => AppEntry(executable: name));
    }
    final list = seen.values.toList()
      ..sort((a, b) =>
          a.executable.toLowerCase().compareTo(b.executable.toLowerCase()));
    return list;
  }

  static List<String> _csvCells(String line) {
    final cells = <String>[];
    final buf = StringBuffer();
    var inQuotes = false;
    for (var i = 0; i < line.length; i++) {
      final c = line[i];
      if (c == '"') {
        inQuotes = !inQuotes;
      } else if (c == ',' && !inQuotes) {
        cells.add(buf.toString());
        buf.clear();
      } else {
        buf.write(c);
      }
    }
    if (buf.isNotEmpty) cells.add(buf.toString());
    return cells;
  }
}
