import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Keeps the quick settings tile and the home screen widget usable.
///
/// Both are drawn outside the Flutter engine — SystemUI builds the tile, the
/// launcher builds the widget — and either can be tapped when the app's process
/// is not running at all. So the last connection is mirrored into the same
/// SharedPreferences file the native side can read, and the native toggle
/// starts the core from that without Dart's help.
class AndroidShortcuts {
  static const _channel = MethodChannel('app.veil/widgets');

  /// Read natively as `flutter.last_vpn_*`; the plugin adds the prefix.
  static const _kConfig = 'last_vpn_config';
  static const _kRemark = 'last_vpn_remark';
  static const _kProxyOnly = 'last_vpn_proxy_only';

  static bool get supported => Platform.isAndroid;

  /// Records what the tile should start if it is tapped later.
  static Future<void> rememberConnection({
    required String configJson,
    required String remark,
    required bool proxyOnly,
  }) async {
    if (!supported) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kConfig, configJson);
      await prefs.setString(_kRemark, remark);
      await prefs.setBool(_kProxyOnly, proxyOnly);
    } catch (e) {
      debugPrint('could not remember connection for the tile: $e');
    }
  }

  /// Forgets it, so the tile offers nothing rather than reconnecting to a
  /// location the user has removed.
  static Future<void> forgetConnection() async {
    if (!supported) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_kConfig);
      await prefs.remove(_kRemark);
    } catch (_) {}
  }

  /// Repaints any placed widgets.
  static Future<void> refreshWidgets() async {
    if (!supported) return;
    try {
      await _channel.invokeMethod<void>('refresh');
    } on PlatformException catch (e) {
      debugPrint('widget refresh failed: $e');
    } on MissingPluginException {
      // Engine not attached — the widget will catch up on its next update.
    }
  }

  /// True when the tunnel that just went down was stopped on purpose.
  ///
  /// Three things outside the app can stop it: the DISCONNECT button on the
  /// ongoing notification, the quick settings tile and the home screen widget.
  /// All three reach the core as a STOP_SERVICE, and none of them can tell Dart
  /// anything — so the app saw a tunnel it still wanted vanish, called that a
  /// drop, and reconnected. Tapping DISCONNECT appeared to start the VPN again,
  /// and the widget appeared to toggle at random.
  ///
  /// Read-and-clear on the native side: one stop is only ever claimed once.
  /// Fails **closed**: an unanswerable question counts as "the user asked".
  ///
  /// The two ways to be wrong are not equal. Reconnecting a tunnel somebody
  /// deliberately switched off is the bug being fixed here and it is
  /// infuriating; declining to auto-recover from a genuine drop costs one tap.
  static Future<bool> consumeUserStop() async {
    if (!supported) return false;
    try {
      return await _channel.invokeMethod<bool>('consumeUserStop') ?? true;
    } on PlatformException catch (e) {
      debugPrint('user-stop check failed, assuming the user asked: $e');
      return true;
    } on MissingPluginException {
      // The engine is not attached, so nobody is watching the UI either.
      return true;
    }
  }

  /// True when a tunnel is up right now, whoever started it.
  ///
  /// Answered natively because the core outlives the Flutter engine: the app
  /// can be cold-started into a process that is already tunnelling.
  static Future<bool> isCoreRunning() async {
    if (!supported) return false;
    try {
      return await _channel.invokeMethod<bool>('isCoreRunning') ?? false;
    } on PlatformException catch (e) {
      debugPrint('core-state check failed: $e');
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// True while anything is still up — connected, or on its way there.
  ///
  /// Stopping the tunnel means sending an intent to a service in another
  /// process and hearing nothing back, so [AndroidVpnEngine.disconnect] uses
  /// this to check the stop actually took rather than assuming it did.
  static Future<bool> isTunnelActive() async {
    if (!supported) return false;
    try {
      return await _channel.invokeMethod<bool>('isTunnelActive') ?? false;
    } on PlatformException catch (e) {
      debugPrint('tunnel-state check failed: $e');
      return false;
    } on MissingPluginException {
      return false;
    }
  }
}
