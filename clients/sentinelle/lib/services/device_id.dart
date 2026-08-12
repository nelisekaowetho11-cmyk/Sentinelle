import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'storage.dart';

/// This installation's identity, as sent to the panel on every call.
///
/// The panel counts *devices* against the account's limit rather than IP
/// addresses. An install id is the honest unit: it survives a wifi-to-mobile
/// switch, and it does not lump every user behind one CGNAT address together.
class DeviceIdentity {
  /// Held in memory so the identity is stable within a run even when
  /// preferences are unavailable (tests, or a call made before startup
  /// finishes).
  static String? _cachedId;
  static String? _cachedName;

  /// Stable id, generated once and kept. Not derived from any hardware
  /// identifier — nothing here should be able to follow a user between
  /// accounts or reinstalls.
  static String get id {
    final store = Storage.maybeI;
    final existing = store?.deviceId ?? '';
    if (existing.isNotEmpty) return existing;

    final fresh = _cachedId ??= _generate();
    // Fire-and-forget: the value is already in memory for this call, and the
    // next launch reads it back from disk.
    store?.setDeviceId(fresh);
    return fresh;
  }

  static String _generate() {
    final rnd = Random.secure();
    final bytes = List<int>.generate(16, (_) => rnd.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  /// Something a person can recognise in a device list.
  static String get name {
    final store = Storage.maybeI;
    final saved = store?.deviceName ?? '';
    if (saved.isNotEmpty) return saved;
    final host = _hostname();
    final value = _cachedName ??= host.isEmpty ? '$platform device' : host;
    store?.setDeviceName(value);
    return value;
  }

  static String _hostname() {
    try {
      return Platform.localHostname;
    } catch (_) {
      return '';
    }
  }

  static String get platform {
    if (kIsWeb) return 'web';
    if (Platform.isAndroid) return 'android';
    if (Platform.isIOS) return 'ios';
    if (Platform.isWindows) return 'windows';
    if (Platform.isMacOS) return 'macos';
    if (Platform.isLinux) return 'linux';
    return 'unknown';
  }

  /// Headers added to every panel request.
  static Map<String, String> get headers => {
        'X-Device-Id': id,
        'X-Device-Name': name,
        'X-Device-Platform': platform,
      };
}
