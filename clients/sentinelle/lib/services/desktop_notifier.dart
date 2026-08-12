import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:local_notifier/local_notifier.dart';

import '../branding.dart';

/// Desktop toasts for the two events worth interrupting someone about: the
/// tunnel came up, and the tunnel went away.
///
/// The window spends most of its life hidden in the tray, so without this the
/// only way to learn the connection dropped is to go looking — which is exactly
/// when it matters least and costs most.
class DesktopNotifier {
  static bool _ready = false;

  static bool get supported =>
      Platform.isWindows || Platform.isMacOS || Platform.isLinux;

  static Future<void> initialize() async {
    if (!supported || _ready) return;
    try {
      await localNotifier.setup(appName: kAppName);
      _ready = true;
    } catch (e) {
      // A desktop with no notification service is a normal state, not a
      // failure worth surfacing.
      debugPrint('notifications unavailable: $e');
    }
  }

  static Future<void> show(String title, String body) async {
    if (!_ready) return;
    try {
      final n = LocalNotification(title: title, body: body);
      await n.show();
    } catch (e) {
      debugPrint('notification failed: $e');
    }
  }

  static Future<void> connected(String location) =>
      show('Connected', 'Traffic is going through $location.');

  /// [reason] is the engine's diagnosis when the tunnel died on its own; a stop
  /// the user asked for has none. [where] names the location that was carrying
  /// the traffic, which is what makes the toast worth reading when several
  /// machines are running.
  static Future<void> disconnected({String? where, String? reason}) => show(
        reason == null ? 'Disconnected' : 'Tunnel dropped',
        reason ??
            (where == null
                ? 'Your traffic is no longer going through the tunnel.'
                : 'Your traffic is no longer going through $where.'),
      );

  static Future<void> failed(String reason) => show('Could not connect', reason);
}
