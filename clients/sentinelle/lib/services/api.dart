import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import '../branding.dart';
import '../models/models.dart';
import 'device_id.dart';
import 'vpn/local_proxy.dart';

class ApiException implements Exception {
  final String message;
  final int? statusCode;

  /// Machine-readable reason, when the panel supplies one. `device_limit` is
  /// the one the UI branches on.
  final String? code;

  /// Extra detail carried alongside an error, e.g. the account's device limit
  /// and the devices currently holding a slot.
  final Map<String, dynamic> details;

  const ApiException(
    this.message, [
    this.statusCode,
    this.code,
    this.details = const {},
  ]);

  bool get isAuthError => statusCode == 401;

  /// The account is already using all of its allowed devices.
  bool get isDeviceLimit => code == 'device_limit';

  int get deviceLimit => (details['ip_limit'] as num?)?.toInt() ?? 0;
  int get devicesInUse => (details['devices_in_use'] as num?)?.toInt() ?? 0;

  /// Devices holding a slot, newest information the panel had.
  List<ClientDevice> get devices => ((details['devices'] as List?) ?? const [])
      .map((e) => ClientDevice.fromJson(Map<String, dynamic>.from(e as Map)))
      .toList();

  @override
  String toString() => message;
}

/// Talks to the Bridge panel's `/api/client/*` endpoints.
class PanelApi {
  PanelApi({
    required String baseUrl,
    this.token,
    this.sourceId = '',
    http.Client? httpClient,
  })  : _baseUrl = baseUrl,
        // Not a plain http.Client(): that goes direct, ignoring both the
        // system proxy and the tunnel the app itself just started. In proxy
        // mode that meant the panel saw the user's real address and reported
        // it back as their exit IP.
        _http = httpClient ?? IOClient(LocalProxy.client());

  String _baseUrl;

  /// May change at runtime: panels behind a proxy usually 301 http→https, and
  /// we follow that upgrade so later calls go straight to the right origin.
  String get baseUrl => _baseUrl;

  String? token;
  final http.Client _http;

  static const _timeout = Duration(seconds: 20);
  static const _maxRedirects = 4;

  /// Tidies user input: `panel.example.com` → `http://panel.example.com`.
  /// Use [resolveBaseUrl] when you can afford a round-trip — it also picks the
  /// right scheme instead of guessing.
  static String normalizeBaseUrl(String raw) {
    var s = raw.trim();
    if (s.isEmpty) return s;
    if (!s.startsWith('http://') && !s.startsWith('https://')) {
      s = '${_guessScheme(s)}://$s';
    }
    while (s.endsWith('/')) {
      s = s.substring(0, s.length - 1);
    }
    return s;
  }

  /// Bare IPs and host:port entries are nearly always a plain-HTTP panel;
  /// a domain name in front of a proxy is nearly always HTTPS.
  ///
  /// [kRequireHttps] overrides the guess entirely: a build that has promised
  /// its store listing that everything is encrypted must not reach for `http`
  /// just because the address looks like one of the panels that usually is.
  static String _guessScheme(String hostPart) {
    if (kRequireHttps) return 'https';
    final host = hostPart.split('/').first;
    final isIpish = RegExp(r'^\d{1,3}(\.\d{1,3}){3}(:\d+)?$').hasMatch(host);
    final hasPort = RegExp(r':\d+$').hasMatch(host);
    if (isIpish || hasPort || host == 'localhost') return 'http';
    return 'https';
  }

  /// Why this address cannot be used, or null when it is fine.
  ///
  /// Returned as a message rather than thrown: every caller is already a
  /// "returns null on success, an error string otherwise" flow, and the point
  /// is to tell the user something they can act on — not to produce a crash
  /// report about a URL they typed.
  static String? plaintextRefusal(String raw) {
    if (!kRequireHttps) return null;
    if (!raw.trim().toLowerCase().startsWith('http://')) return null;
    return 'This address uses plain http://, which would send your username '
        'and password across the network unencrypted. Ask your provider for '
        'their https:// address.';
  }

  /// Probes both schemes and returns the one the panel actually answers on.
  /// Falls back to the best guess when neither responds.
  static Future<String> resolveBaseUrl(String raw) async {
    final input = raw.trim();
    if (input.isEmpty) return input;

    if (input.startsWith('http://') || input.startsWith('https://')) {
      return normalizeBaseUrl(input);
    }

    var host = input;
    while (host.endsWith('/')) {
      host = host.substring(0, host.length - 1);
    }

    final preferred = _guessScheme(host);
    final candidates = kRequireHttps
        // No fallback to probe: reaching for http after https fails is exactly
        // the downgrade this build exists without.
        ? ['https://$host']
        : preferred == 'https'
            ? ['https://$host', 'http://$host']
            : ['http://$host', 'https://$host'];

    for (final c in candidates) {
      final api = PanelApi(baseUrl: c);
      try {
        await api.ping();
        return api.baseUrl; // ping already followed any redirect
      } catch (_) {
        // try the next scheme
      } finally {
        api.close();
      }
    }
    return candidates.first;
  }

  Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        'Accept': 'application/json',
        'User-Agent': '$kAppName/1.0',
        // Lets the panel count devices against the account's limit without
        // resorting to IP addresses.
        ...DeviceIdentity.headers,
        if (token != null && token!.isNotEmpty) 'Authorization': 'Bearer $token',
      };

  /// Sends a request, following redirects **without downgrading the method**.
  ///
  /// dart:io turns a redirected POST into a GET (per the old HTTP spec), which
  /// makes every POST endpoint answer 405 as soon as the panel sits behind an
  /// http→https redirect. So we handle 3xx ourselves.
  Future<http.Response> _send(String method, String path, {Object? body}) async {
    var url = Uri.parse('$_baseUrl$path');
    final originalOrigin = Uri.parse(_baseUrl).origin;

    for (var hop = 0; hop <= _maxRedirects; hop++) {
      final req = http.Request(method, url)
        ..followRedirects = false
        ..headers.addAll(_headers);
      if (body != null) req.body = jsonEncode(body);

      final streamed = await _http.send(req).timeout(_timeout);
      final res = await http.Response.fromStream(streamed);

      final isRedirect = const [301, 302, 303, 307, 308].contains(res.statusCode);
      final location = res.headers['location'];
      if (!isRedirect || location == null || location.isEmpty) {
        return res;
      }

      final next = url.resolve(location);
      // Remember an origin change (typically http → https) for later calls.
      if (next.origin != originalOrigin && next.path == url.path) {
        _baseUrl = next.origin;
      }
      url = next;
    }

    throw const ApiException('Too many redirects from the panel');
  }

  Map<String, dynamic> _decode(http.Response r) {
    final text = utf8.decode(r.bodyBytes, allowMalformed: true);
    Map<String, dynamic> body;
    try {
      body = jsonDecode(text) as Map<String, dynamic>;
    } catch (_) {
      throw ApiException(_describeNonJson(r, text), r.statusCode);
    }
    if (r.statusCode >= 400) {
      throw ApiException(
        (body['error'] as String?) ?? 'Request failed (${r.statusCode})',
        r.statusCode,
        body['code'] as String?,
        body,
      );
    }
    return body;
  }

  String _describeNonJson(http.Response r, String text) {
    if (r.statusCode == 404) {
      return 'This panel does not expose the client API (404). '
          'Ask your provider to update the panel.';
    }
    if (r.statusCode == 405) {
      return 'The panel rejected the request method (405). '
          'Check that the address points straight at the panel.';
    }
    final looksLikeHtml = text.trimLeft().toLowerCase().startsWith('<');
    if (looksLikeHtml) {
      return 'Got a web page instead of data (HTTP ${r.statusCode}). '
          'Check the panel address.';
    }
    final snippet = text.trim();
    return 'Unexpected response from server (HTTP ${r.statusCode})'
        '${snippet.isEmpty ? '' : ': ${snippet.substring(0, snippet.length.clamp(0, 120))}'}';
  }

  Future<Map<String, dynamic>> _request(String method, String path,
      {Object? body}) async {
    try {
      return _decode(await _send(method, path, body: body));
    } on ApiException {
      rethrow;
    } on TimeoutException {
      throw const ApiException('The server took too long to respond');
    } on SocketException catch (e) {
      throw ApiException(
          'Cannot reach the server (${e.osError?.message ?? e.message})');
    } on HandshakeException {
      throw const ApiException(
          'TLS handshake failed — the panel certificate was rejected');
    } on http.ClientException catch (e) {
      throw ApiException('Network error: ${e.message}');
    } catch (e) {
      throw ApiException('Network error: $e');
    }
  }

  Future<Map<String, dynamic>> _get(String path) => _request('GET', path);

  Future<Map<String, dynamic>> _post(String path, [Map<String, dynamic>? body]) =>
      _request('POST', path, body: body ?? const {});

  /// Reachability probe used by the "panel address" field.
  Future<String> ping() async {
    final j = await _get('/api/client/ping');
    if (j['ok'] != true) throw const ApiException('That address is not a compatible panel');
    return (j['panel'] ?? kAppName) as String;
  }

  /// Tags every server this panel returns with the source it belongs to, so
  /// two panels numbering their servers from 1 stay distinguishable.
  String sourceId;

  Future<({String token, ClientSession session})> login(
      String username, String password) async {
    final j = await _post('/api/client/login', {
      'username': username,
      'password': password,
    });
    final t = j['token'] as String;
    token = t;
    return (token: t, session: ClientSession.fromJson(j, sourceId: sourceId));
  }

  Future<ClientSession> session() async => ClientSession.fromJson(
        await _get('/api/client/session'),
        sourceId: sourceId,
      );

  Future<Profile> profile() async {
    final j = await _get('/api/client/profile');
    return Profile.fromJson(Map<String, dynamic>.from(j['profile'] as Map));
  }

  /// Latest client build for [platform]; unauthenticated so an app too old to
  /// sign in can still find its update.
  Future<Map<String, dynamic>> checkUpdate(String platform, String version) =>
      _get('/api/client/update?platform=$platform&version=$version');

  /// Hands this device's slot back to the panel.
  ///
  /// Signing out used to be silent, so the slot stayed held for the whole
  /// silence window — which is how signing out on a laptop left the phone
  /// unable to connect for the next ten minutes. Best effort by design: an
  /// unreachable panel still ages the slot out on its own.
  Future<void> logout() async {
    try {
      // Deliberately shorter than the usual timeout: signing out must feel
      // instant, and a panel that is not answering will age the slot out by
      // itself within the silence window anyway.
      await _post('/api/client/logout').timeout(const Duration(seconds: 4));
    } catch (_) {
      // Nothing to recover — the caller is signing out either way.
    }
  }

  /// Signs one of the account's *other* devices out, freeing its slot.
  ///
  /// Takes credentials as well as the token, because the app that most needs
  /// this is the one that was just refused a token for being over the limit.
  Future<List<ClientDevice>> releaseDevice(
    String deviceId, {
    String username = '',
    String password = '',
  }) async {
    final j = await _post('/api/client/devices/release', {
      'id': deviceId,
      if (username.isNotEmpty) 'username': username,
      if (password.isNotEmpty) 'password': password,
    });
    return ((j['devices'] as List?) ?? const [])
        .map((e) => ClientDevice.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
  }

  Future<({Profile profile, bool canConnect, String? blockedReason})>
      heartbeat() async {
    final j = await _post('/api/client/heartbeat');
    return (
      profile: Profile.fromJson(Map<String, dynamic>.from(j['profile'] as Map)),
      canConnect: (j['can_connect'] ?? false) as bool,
      blockedReason: j['blocked_reason'] as String?,
    );
  }

  void close() => _http.close();
}
