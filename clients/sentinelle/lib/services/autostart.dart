import 'dart:io';

import '../branding.dart';

/// Starts the app when the user signs in. Desktop only.
///
/// Each platform has one mechanism the desktop actually reads, and none of them
/// need elevation — all three write inside the user's own profile, which is
/// what makes this safe to toggle from a settings screen.
///
///  * Windows — a value under `HKCU\...\CurrentVersion\Run`.
///  * Linux   — a `.desktop` file in `~/.config/autostart`.
///  * macOS   — a LaunchAgent plist in `~/Library/LaunchAgents`.
class AutoStart {
  AutoStart._();

  static bool get supported =>
      Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  /// The name the entry is filed under. Stable across versions on purpose: a
  /// rename would orphan the old entry and start the app twice.
  static const _entryName = 'Sentinelle';
  static const _bundleId = 'app.veil.sentinelle';

  static const _runKey =
      r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run';

  /// Where Windows puts per-user startup shortcuts. The installer offers to
  /// drop one here, so it counts as "enabled" too — and has to be removed when
  /// the user turns this off, or the app would keep starting anyway.
  static Future<File?> _windowsStartupShortcut() async {
    final appData = Platform.environment['APPDATA'];
    if (appData == null || appData.isEmpty) return null;
    return File('$appData\\Microsoft\\Windows\\Start Menu\\Programs\\Startup\\'
        '$_entryName.lnk');
  }

  /// True when this machine is set to launch the app at sign-in.
  static Future<bool> isEnabled() async {
    if (!supported) return false;
    try {
      if (Platform.isWindows) {
        final shortcut = await _windowsStartupShortcut();
        if (shortcut != null && await shortcut.exists()) return true;
        final r = await Process.run(
            'reg', ['query', _runKey, '/v', _entryName]);
        return r.exitCode == 0;
      }
      return await (await _unixEntry()).exists();
    } catch (_) {
      return false;
    }
  }

  /// Returns whether the machine ended up in the requested state.
  static Future<bool> setEnabled(bool enabled) async {
    if (!supported) return false;
    try {
      if (Platform.isWindows) {
        await _setWindows(enabled);
      } else if (Platform.isMacOS) {
        await _setMacOS(enabled);
      } else {
        await _setLinux(enabled);
      }
      return await isEnabled() == enabled;
    } catch (_) {
      return false;
    }
  }

  // ── Windows ────────────────────────────────────────────────────────────────

  static Future<void> _setWindows(bool enabled) async {
    if (enabled) {
      // Quoted: the executable lives under "Program Files", and an unquoted
      // path with a space in it is the classic way this silently does nothing.
      await Process.run('reg', [
        'add', _runKey, '/v', _entryName, '/t', 'REG_SZ',
        '/d', '"${Platform.resolvedExecutable}"', '/f',
      ]);
      return;
    }
    await Process.run('reg', ['delete', _runKey, '/v', _entryName, '/f']);
    // The installer's own startup shortcut would otherwise keep launching the
    // app after the user turned this off.
    final shortcut = await _windowsStartupShortcut();
    if (shortcut != null && await shortcut.exists()) {
      try {
        await shortcut.delete();
      } catch (_) {}
    }
  }

  // ── Linux / macOS ──────────────────────────────────────────────────────────

  static Future<File> _unixEntry() async {
    final home = Platform.environment['HOME'] ?? '';
    if (Platform.isMacOS) {
      return File('$home/Library/LaunchAgents/$_bundleId.plist');
    }
    final base = Platform.environment['XDG_CONFIG_HOME'];
    final dir = (base == null || base.isEmpty) ? '$home/.config' : base;
    return File('$dir/autostart/${_bundleId.replaceAll('.', '-')}.desktop');
  }

  static Future<void> _setLinux(bool enabled) async {
    final file = await _unixEntry();
    if (!enabled) {
      if (await file.exists()) await file.delete();
      return;
    }
    await file.parent.create(recursive: true);
    await file.writeAsString('''
[Desktop Entry]
Type=Application
Name=$kAppName
Exec="${Platform.resolvedExecutable}"
X-GNOME-Autostart-enabled=true
Terminal=false
''', flush: true);
  }

  static Future<void> _setMacOS(bool enabled) async {
    final file = await _unixEntry();
    if (!enabled) {
      if (await file.exists()) {
        await Process.run('launchctl', ['unload', file.path]);
        await file.delete();
      }
      return;
    }
    await file.parent.create(recursive: true);
    await file.writeAsString('''
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$_bundleId</string>
  <key>ProgramArguments</key>
  <array><string>${Platform.resolvedExecutable}</string></array>
  <key>RunAtLoad</key><true/>
</dict>
</plist>
''', flush: true);
    await Process.run('launchctl', ['load', file.path]);
  }

  /// Where the entry lives, for the settings screen to explain itself.
  static Future<String> describe() async {
    if (Platform.isWindows) return 'Registered under HKCU\\…\\Run';
    try {
      return (await _unixEntry()).path;
    } catch (_) {
      return '';
    }
  }
}
