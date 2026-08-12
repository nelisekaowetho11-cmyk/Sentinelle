import 'dart:io';

import 'package:archive/archive.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

enum CoreKind { xray, singbox }

class CoreDownloadException implements Exception {
  CoreDownloadException(this.message, {this.attempts = const []});
  final String message;
  final List<String> attempts;
  @override
  String toString() => message;
}

/// Finds, downloads and version-checks the proxy cores the desktop app runs.
///
/// Lookup order for both cores:
///   1. explicit path from settings
///   2. next to the app executable (what a bundled build ships)
///   3. the managed copy in the app-support directory
///   4. on PATH
class CoreManager {
  static String exeName(CoreKind kind) {
    final base = kind == CoreKind.xray ? 'xray' : 'sing-box';
    return Platform.isWindows ? '$base.exe' : base;
  }

  static String label(CoreKind kind) =>
      kind == CoreKind.xray ? 'Xray' : 'sing-box';

  /// Pinned fallbacks, used when the release API is unreachable — which it
  /// often is from the networks this app exists to get around.
  static const _pinned = {
    CoreKind.xray: '25.3.6',
    CoreKind.singbox: '1.13.18',
  };

  static Future<Directory> coreDir() async {
    final base = await getApplicationSupportDirectory();
    final dir = Directory('${base.path}${Platform.pathSeparator}core');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  static Future<String?> resolve(CoreKind kind, String explicitPath) async {
    final name = exeName(kind);

    if (explicitPath.trim().isNotEmpty && await File(explicitPath).exists()) {
      return explicitPath;
    }
    final beside = _besideExecutable(name);
    if (beside != null && await File(beside).exists()) return beside;

    final managed = '${(await coreDir()).path}${Platform.pathSeparator}$name';
    if (await File(managed).exists()) return managed;

    return _onPath(name);
  }

  static String? _besideExecutable(String name) {
    try {
      final exeDir = File(Platform.resolvedExecutable).parent.path;
      return '$exeDir${Platform.pathSeparator}$name';
    } catch (_) {
      return null;
    }
  }

  static Future<String?> _onPath(String name) async {
    try {
      final r = await Process.run(Platform.isWindows ? 'where' : 'which', [name]);
      if (r.exitCode == 0) {
        final line = (r.stdout as String).split('\n').first.trim();
        if (line.isNotEmpty && await File(line).exists()) return line;
      }
    } catch (_) {}
    return null;
  }

  static String _arch() {
    final env = (Platform.environment['PROCESSOR_ARCHITECTURE'] ?? '').toLowerCase();
    if (env.contains('arm64')) return 'arm64';
    if (Platform.version.toLowerCase().contains('arm64')) return 'arm64';
    return 'amd64';
  }

  static String _os() {
    if (Platform.isWindows) return 'windows';
    if (Platform.isMacOS) return 'macos';
    return 'linux';
  }

  /// Release asset name for this machine.
  static String assetName(CoreKind kind, String version) {
    final arch = _arch();
    if (kind == CoreKind.xray) {
      final map = {
        'windows-amd64': 'Xray-windows-64.zip',
        'windows-arm64': 'Xray-windows-arm64-v8a.zip',
        'macos-amd64': 'Xray-macos-64.zip',
        'macos-arm64': 'Xray-macos-arm64-v8a.zip',
        'linux-amd64': 'Xray-linux-64.zip',
        'linux-arm64': 'Xray-linux-arm64-v8a.zip',
      };
      return map['${_os()}-$arch'] ?? 'Xray-linux-64.zip';
    }
    // sing-box publishes .zip for windows/macos and .tar.gz for linux
    final ext = _os() == 'linux' ? 'tar.gz' : 'zip';
    return 'sing-box-$version-${_os()}-$arch.$ext';
  }

  static String _repo(CoreKind kind) =>
      kind == CoreKind.xray ? 'XTLS/Xray-core' : 'SagerNet/sing-box';

  /// Candidate URLs, in order. Direct GitHub first, then mirrors that are
  /// commonly reachable where GitHub is not.
  static List<String> _urls(CoreKind kind, String version, String asset) {
    final tag = kind == CoreKind.xray ? 'v$version' : 'v$version';
    final direct =
        'https://github.com/${_repo(kind)}/releases/download/$tag/$asset';
    return [
      direct,
      'https://ghfast.top/$direct',
      'https://gh-proxy.com/$direct',
      'https://ghproxy.net/$direct',
    ];
  }

  static Future<String?> _latestVersion(CoreKind kind) async {
    try {
      final r = await http.get(
        Uri.parse('https://api.github.com/repos/${_repo(kind)}/releases/latest'),
        headers: {
          'Accept': 'application/vnd.github+json',
          'User-Agent': 'VeilClient',
        },
      ).timeout(const Duration(seconds: 12));
      if (r.statusCode != 200) return null;
      final tag = RegExp(r'"tag_name"\s*:\s*"v?([^"]+)"').firstMatch(r.body);
      return tag?.group(1);
    } catch (_) {
      return null;
    }
  }

  /// Downloads the core into the managed directory, trying each mirror.
  /// Reports 0..1 progress plus a human-readable note.
  static Future<String> download(
    CoreKind kind, {
    void Function(double progress, String note)? onProgress,
  }) async {
    onProgress?.call(0.02, 'Checking for the latest ${label(kind)}…');
    final version = await _latestVersion(kind) ?? _pinned[kind]!;
    final asset = assetName(kind, version);
    final urls = _urls(kind, version, asset);

    final attempts = <String>[];
    for (var i = 0; i < urls.length; i++) {
      final url = urls[i];
      final host = Uri.parse(url).host;
      try {
        onProgress?.call(0.05, 'Downloading ${label(kind)} $version from $host…');
        final bytes = await _fetch(url, (p) {
          onProgress?.call(0.05 + 0.80 * p,
              'Downloading ${label(kind)} $version from $host…');
        });
        onProgress?.call(0.88, 'Extracting…');
        final path = await _extract(kind, asset, bytes);
        onProgress?.call(1, '${label(kind)} $version installed');
        return path;
      } catch (e) {
        attempts.add('$host — $e');
      }
    }

    throw CoreDownloadException(
      'Could not download ${label(kind)} $version. GitHub and all mirrors '
      'failed. You can install it manually instead: download $asset, unzip it, '
      'and point Settings → Custom core path at the ${exeName(kind)} file.',
      attempts: attempts,
    );
  }

  static Future<List<int>> _fetch(
      String url, void Function(double) onProgress) async {
    final client = http.Client();
    try {
      final req = http.Request('GET', Uri.parse(url))
        ..headers['User-Agent'] = 'VeilClient'
        ..followRedirects = true;
      final resp = await client.send(req).timeout(const Duration(seconds: 45));
      if (resp.statusCode != 200) {
        throw 'HTTP ${resp.statusCode}';
      }
      final total = resp.contentLength ?? 0;
      final bytes = <int>[];
      await for (final chunk in resp.stream.timeout(const Duration(seconds: 60))) {
        bytes.addAll(chunk);
        if (total > 0) onProgress(bytes.length / total);
      }
      if (bytes.length < 1024) throw 'response too small (${bytes.length} bytes)';
      return bytes;
    } finally {
      client.close();
    }
  }

  /// Everything we keep out of a release archive.
  static bool _wanted(CoreKind kind, String fileName) {
    final want = <String>{
      exeName(kind),
      if (kind == CoreKind.xray) ...['geoip.dat', 'geosite.dat'],
      if (kind == CoreKind.singbox && Platform.isWindows) 'libcronet.dll',
      if (kind == CoreKind.singbox && !Platform.isWindows) 'libcronet.so',
    };
    return want.contains(fileName);
  }

  static Future<String> _extract(
      CoreKind kind, String assetName, List<int> bytes) async {
    final dir = await coreDir();
    final Archive archive;
    if (assetName.endsWith('.tar.gz')) {
      archive = TarDecoder().decodeBytes(GZipDecoder().decodeBytes(bytes));
    } else {
      archive = ZipDecoder().decodeBytes(bytes);
    }

    String? exePath;
    for (final f in archive) {
      if (!f.isFile) continue;
      final name = f.name.split('/').last.split('\\').last;
      if (!_wanted(kind, name)) continue;
      final out = File('${dir.path}${Platform.pathSeparator}$name');
      await out.writeAsBytes(f.readBytes() ?? const <int>[], flush: true);
      if (name == exeName(kind)) exePath = out.path;
    }

    if (exePath == null) {
      throw 'archive did not contain ${exeName(kind)}';
    }
    if (!Platform.isWindows) {
      await Process.run('chmod', ['+x', exePath]);
    }
    return exePath;
  }

  static Future<String> version(String corePath) async {
    try {
      final r = await Process.run(corePath, ['version'])
          .timeout(const Duration(seconds: 8));
      final first = (r.stdout as String)
          .split('\n')
          .map((s) => s.trim())
          .firstWhere((s) => s.isNotEmpty, orElse: () => '');
      return first;
    } catch (_) {
      return '';
    }
  }

  /// Copies a user-picked binary into the managed directory so the app owns a
  /// stable path even if the original is moved.
  static Future<String> adoptBinary(CoreKind kind, String sourcePath) async {
    final src = File(sourcePath);
    if (!await src.exists()) throw 'File not found: $sourcePath';
    final dir = await coreDir();
    final dest = File('${dir.path}${Platform.pathSeparator}${exeName(kind)}');
    await src.copy(dest.path);
    if (!Platform.isWindows) {
      await Process.run('chmod', ['+x', dest.path]);
    }
    return dest.path;
  }
}
