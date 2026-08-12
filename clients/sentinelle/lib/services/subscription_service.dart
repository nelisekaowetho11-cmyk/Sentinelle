import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import '../branding.dart';
import '../models/models.dart';
import 'share_link.dart';
import 'vpn/local_proxy.dart';

/// Fetches a subscription URL from someone else's panel and turns it into
/// locations.
///
/// Subscription endpoints are a de-facto standard rather than a real one: most
/// return a base64 blob of share links, some return them in the clear, a few
/// return JSON. All three are handled, and the useful metadata some panels put
/// in headers is read where present.
class SubscriptionService {
  SubscriptionService({http.Client? httpClient})
      // Through the tunnel when one is up: a subscription URL is exactly the
      // kind of address the networks this app exists for like to block.
      : _http = httpClient ?? IOClient(LocalProxy.client());

  final http.Client _http;

  static const _timeout = Duration(seconds: 25);

  /// Many panels vary what they return based on the client asking. Announcing
  /// ourselves honestly gets the generic share-link list, which is the one
  /// format we can actually parse.
  static const _userAgent = '$kAppName/1.0';

  Future<SubscriptionResult> fetch(String rawUrl,
      {required String sourceId}) async {
    final url = _normalise(rawUrl);
    if (url == null) {
      return SubscriptionResult.failed('That does not look like a URL.');
    }

    late final http.Response res;
    try {
      res = await _http.get(url, headers: {
        'User-Agent': _userAgent,
        'Accept': '*/*',
      }).timeout(_timeout);
    } on TimeoutException {
      return SubscriptionResult.failed('The subscription took too long to answer.');
    } on SocketException catch (e) {
      return SubscriptionResult.failed(
          'Cannot reach the subscription (${e.osError?.message ?? e.message}).');
    } catch (e) {
      return SubscriptionResult.failed('Could not fetch the subscription: $e');
    }

    if (res.statusCode >= 400) {
      return SubscriptionResult.failed(
          'The subscription answered HTTP ${res.statusCode}.');
    }

    final body = utf8.decode(res.bodyBytes, allowMalformed: true);
    final parsed = _parseBody(body, sourceId: sourceId);

    if (parsed.isEmpty) {
      return SubscriptionResult.failed(
        parsed.failures.isEmpty
            ? 'The subscription returned nothing this app can use.'
            : 'No usable configs. First problem: ${parsed.failures.first}',
      );
    }

    return SubscriptionResult(
      servers: parsed.servers,
      failures: parsed.failures,
      title: _title(res.headers),
      usage: SubscriptionUsage.fromHeader(res.headers['subscription-userinfo']),
    );
  }

  /// JSON first — a few panels serve an array of outbound objects — then the
  /// share-link path, which covers everything else.
  ParsedLinks _parseBody(String body, {required String sourceId}) {
    final trimmed = body.trim();
    if (trimmed.startsWith('[') || trimmed.startsWith('{')) {
      final fromJson = _tryJson(trimmed, sourceId);
      if (fromJson != null) return fromJson;
    }
    return ShareLink.parseMany(trimmed, sourceId: sourceId);
  }

  ParsedLinks? _tryJson(String body, String sourceId) {
    try {
      final decoded = jsonDecode(body);
      final list = decoded is List
          ? decoded
          : (decoded as Map<String, dynamic>)['servers'] as List?;
      if (list == null) return null;

      final servers = <ServerConfig>[];
      for (final item in list) {
        final map = Map<String, dynamic>.from(item as Map);
        // A panel-shaped entry we can consume directly.
        if (map.containsKey('outbound')) {
          servers.add(ServerConfig.fromJson(map, sourceId: sourceId));
          continue;
        }
        // Otherwise look for a link field and fall back to the parser.
        final link = (map['link'] ?? map['url'] ?? '') as String;
        if (link.isEmpty) continue;
        final s = ShareLink.parse(link, sourceId: sourceId);
        if (s != null) servers.add(s);
      }
      return servers.isEmpty
          ? null
          : ParsedLinks(servers: servers, failures: const []);
    } catch (_) {
      return null;
    }
  }

  static Uri? _normalise(String raw) {
    var s = raw.trim();
    if (s.isEmpty) return null;
    if (!s.startsWith('http://') && !s.startsWith('https://')) {
      s = 'https://$s';
    }
    final u = Uri.tryParse(s);
    if (u == null || u.host.isEmpty) return null;
    return u;
  }

  static String? _title(Map<String, String> headers) {
    final raw = headers['profile-title'];
    if (raw == null || raw.isEmpty) return null;
    // Panels commonly send this base64-encoded so non-ASCII names survive.
    if (raw.startsWith('base64:')) {
      try {
        return utf8.decode(base64.decode(raw.substring('base64:'.length)));
      } catch (_) {
        return null;
      }
    }
    return raw;
  }

  void close() => _http.close();
}

/// Quota a subscription reports in its `subscription-userinfo` header.
class SubscriptionUsage {
  const SubscriptionUsage({
    this.uploadBytes = 0,
    this.downloadBytes = 0,
    this.totalBytes = 0,
    this.expiry,
  });

  final int uploadBytes;
  final int downloadBytes;

  /// 0 means the panel did not say, which we present as unlimited rather than
  /// as "no quota left".
  final int totalBytes;
  final DateTime? expiry;

  int get usedBytes => uploadBytes + downloadBytes;
  bool get unlimited => totalBytes <= 0;

  double get usedPct =>
      unlimited ? 0 : (usedBytes / totalBytes * 100).clamp(0, 100).toDouble();

  /// `upload=1234; download=2345; total=105906176; expire=1596025260`
  static SubscriptionUsage? fromHeader(String? header) {
    if (header == null || header.trim().isEmpty) return null;
    final values = <String, int>{};
    for (final part in header.split(';')) {
      final kv = part.split('=');
      if (kv.length != 2) continue;
      final v = int.tryParse(kv[1].trim());
      if (v != null) values[kv[0].trim().toLowerCase()] = v;
    }
    if (values.isEmpty) return null;
    final expire = values['expire'] ?? 0;
    return SubscriptionUsage(
      uploadBytes: values['upload'] ?? 0,
      downloadBytes: values['download'] ?? 0,
      totalBytes: values['total'] ?? 0,
      expiry: expire > 0
          ? DateTime.fromMillisecondsSinceEpoch(expire * 1000)
          : null,
    );
  }
}

class SubscriptionResult {
  const SubscriptionResult({
    required this.servers,
    this.failures = const [],
    this.title,
    this.usage,
    this.error,
  });

  const SubscriptionResult.failed(String message)
      : servers = const [],
        failures = const [],
        title = null,
        usage = null,
        error = message;

  final List<ServerConfig> servers;
  final List<String> failures;

  /// Name the panel suggests for this subscription.
  final String? title;
  final SubscriptionUsage? usage;
  final String? error;

  bool get ok => error == null;
}
