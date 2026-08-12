import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

import '../branding.dart';
import 'api.dart';
import 'vpn/local_proxy.dart';

class UpdateInfo {
  const UpdateInfo({
    required this.available,
    required this.latest,
    required this.current,
    required this.url,
    required this.notes,
    required this.mandatory,
  });

  final bool available;
  final String latest;
  final String current;
  final String url;
  final String notes;
  final bool mandatory;

  static const none = UpdateInfo(
    available: false,
    latest: '',
    current: '',
    url: '',
    notes: '',
    mandatory: false,
  );

  /// True when the client can fetch and start the new build itself, rather than
  /// handing the user a link and hoping.
  ///
  /// Always false in the Play build — see [kSelfUpdate].
  bool get installable =>
      kSelfUpdate &&
      available &&
      url.isNotEmpty &&
      (Platform.isAndroid || Platform.isWindows) &&
      Uri.tryParse(url)?.hasScheme == true;
}

/// Asks the panel whether a newer client build exists for this platform, and
/// fetches it when there is one.
///
/// The panel is the source of truth here rather than a store or GitHub: the
/// people running these panels distribute the apps themselves, often to
/// networks where neither is reachable.
class UpdateService {
  static String get platformKey {
    if (Platform.isAndroid) return 'android';
    if (Platform.isWindows) return 'windows';
    if (Platform.isMacOS) return 'macos';
    return 'linux';
  }

  /// This build's version *including* its build number.
  ///
  /// `PackageInfo.version` alone is what made an up-to-date app keep offering
  /// its own update: a pubspec `1.2.0+3` reports version "1.2.0", so a panel
  /// publishing "1.2.0.3" compared 1.2.0.3 against 1.2.0 and found it newer,
  /// for ever. The build number is part of the version everywhere it is
  /// published, so it has to be part of the version we compare.
  static String versionOf(PackageInfo info) => info.buildNumber.trim().isEmpty
      ? info.version
      : '${info.version}+${info.buildNumber}';

  /// Orders two versions numerically: >0 when [a] is newer, 0 when they match.
  ///
  /// Separators are interchangeable (`1.2.0+3`, `1.2.0.3` and `1.2.0-3` are the
  /// same build) and non-digits are dropped, so `v1.2.0-beta` still compares.
  /// Missing trailing components count as zero, which is what makes `1.2.0`
  /// and `1.2.0+0` equal rather than one being newer than the other.
  static int compareVersions(String a, String b) {
    List<int> parts(String v) => v
        .split(RegExp(r'[.\-+_ ]'))
        .map((chunk) {
          final digits = chunk.replaceAll(RegExp(r'\D'), '');
          return digits.isEmpty ? 0 : (int.tryParse(digits) ?? 0);
        })
        .toList();

    final pa = parts(a);
    final pb = parts(b);
    for (var i = 0; i < (pa.length > pb.length ? pa.length : pb.length); i++) {
      final x = i < pa.length ? pa[i] : 0;
      final y = i < pb.length ? pb[i] : 0;
      if (x != y) return x > y ? 1 : -1;
    }
    return 0;
  }

  static Future<UpdateInfo> check(PanelApi api) async {
    // The store owns updates in the Play build, and it is better at it than we
    // are: telling someone a version exists that the app is forbidden to fetch
    // is a dead end with a button on it.
    if (!kSelfUpdate) return UpdateInfo.none;
    try {
      final info = await PackageInfo.fromPlatform();
      final current = versionOf(info);
      final j = await api.checkUpdate(platformKey, current);

      final latest = (j['latest'] ?? '') as String;
      if (latest.isEmpty) return UpdateInfo.none;

      // Decided here rather than taken from the panel's `update_available`.
      // Older panels answer that flag by comparing against whatever version
      // string they were sent, and they have no idea a build number exists —
      // so an app that has already updated keeps being told to update.
      return UpdateInfo(
        available: compareVersions(latest, current) > 0,
        latest: latest,
        current: current,
        url: (j['url'] ?? '') as String,
        notes: (j['notes'] ?? '') as String,
        mandatory: (j['mandatory'] ?? false) as bool,
      );
    } catch (_) {
      // An unreachable or older panel simply means "no update information".
      return UpdateInfo.none;
    }
  }

  // ── Downloading and installing ─────────────────────────────────────────────

  static const _channel = MethodChannel('app.veil/updates');

  /// Where downloads land. App-private on Android so no storage permission is
  /// needed; the FileProvider hands the installer a grant for it.
  static Future<Directory> _downloadDir() async {
    final base = await getApplicationSupportDirectory();
    final dir = Directory('${base.path}${Platform.pathSeparator}updates');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  static String _fileName(UpdateInfo info) {
    final fromUrl = Uri.parse(info.url).pathSegments.isEmpty
        ? ''
        : Uri.parse(info.url).pathSegments.last;
    if (fromUrl.contains('.')) return fromUrl;
    final ext = Platform.isAndroid ? 'apk' : (Platform.isWindows ? 'exe' : 'bin');
    return 'sentinelle-${info.latest}.$ext';
  }

  /// Fetches the published build, reporting progress 0…1.
  ///
  /// Streamed rather than buffered: an APK or installer is tens of megabytes,
  /// and holding one in memory on a phone to then write it out is a needless
  /// way to be killed.
  static Future<File> download(
    UpdateInfo info, {
    void Function(double progress, int received, int total)? onProgress,
  }) async {
    final dir = await _downloadDir();
    final target = File('${dir.path}${Platform.pathSeparator}${_fileName(info)}');
    final partial = File('${target.path}.part');

    // Through the tunnel when one is up — the same reasoning as the panel
    // itself: an update the user cannot reach is not an update.
    final client = IOClient(LocalProxy.client());
    try {
      final res = await client
          .send(http.Request('GET', Uri.parse(info.url)))
          .timeout(const Duration(seconds: 60));
      if (res.statusCode >= 400) {
        throw UpdateDownloadException(
            'The download link returned HTTP ${res.statusCode}.');
      }

      final total = res.contentLength ?? 0;
      var received = 0;
      final sink = partial.openWrite();
      try {
        await for (final chunk in res.stream) {
          sink.add(chunk);
          received += chunk.length;
          onProgress?.call(
            total > 0 ? (received / total).clamp(0.0, 1.0) : 0.0,
            received,
            total,
          );
        }
      } finally {
        await sink.close();
      }

      // Only now is it a complete file. Renaming last means an interrupted
      // download can never be handed to the installer.
      if (await target.exists()) await target.delete();
      await partial.rename(target.path);
      return target;
    } on UpdateDownloadException {
      rethrow;
    } catch (e) {
      throw UpdateDownloadException('Could not download the update: $e');
    } finally {
      client.close();
      if (await partial.exists()) {
        try {
          await partial.delete();
        } catch (_) {}
      }
    }
  }

  /// Hands the downloaded build to whatever installs software on this platform.
  ///
  /// Returns true when the app should now quit: a Windows installer cannot
  /// replace files that are still open, and Android's package installer takes
  /// over the screen either way.
  static Future<bool> install(File file) async {
    if (Platform.isAndroid) {
      // The system installer shows its own confirmation, so this is a request
      // to open it rather than an install happening behind the user's back.
      await _channel.invokeMethod<void>('install', {'path': file.path});
      return false;
    }
    if (Platform.isWindows) {
      await Process.start(file.path, const [],
          mode: ProcessStartMode.detached, runInShell: false);
      return true;
    }
    // Linux and macOS builds are archives and disk images — there is nothing
    // sensible to run, so reveal the file and let the user take it from there.
    await Process.start(
      Platform.isMacOS ? 'open' : 'xdg-open',
      [file.parent.path],
      mode: ProcessStartMode.detached,
    );
    return false;
  }
}

class UpdateDownloadException implements Exception {
  const UpdateDownloadException(this.message);
  final String message;

  @override
  String toString() => message;
}
