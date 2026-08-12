import 'dart:convert';

import '../models/models.dart';

/// Turns the share links people paste around — `vless://`, `vmess://`,
/// `trojan://`, `ss://` — into [ServerConfig]s.
///
/// The output carries an **Xray-shaped** `outbound`, because that is the shape
/// the panel already hands us and therefore the shape both config builders
/// know how to consume: the Android core takes it verbatim and
/// `SingBoxConfigBuilder` translates it. Parsing to a third shape would have
/// meant teaching both builders a second dialect.
class ShareLink {
  /// Protocols we can actually carry. Anything else is reported rather than
  /// imported half-working — a location that cannot connect is worse than one
  /// that was never added.
  static const supportedSchemes = {'vless', 'vmess', 'trojan', 'ss'};

  /// Parses every link in [text], skipping blanks and comment lines.
  ///
  /// Accepts a bare list, a base64 blob (what most subscription endpoints
  /// return) or a mix, so the same function serves the clipboard and the
  /// subscription fetcher.
  static ParsedLinks parseMany(String text, {required String sourceId}) {
    final body = _maybeBase64(text.trim());
    final servers = <ServerConfig>[];
    final failures = <String>[];
    var index = 0;

    for (final raw in const LineSplitter().convert(body)) {
      final line = raw.trim();
      if (line.isEmpty || line.startsWith('#') || line.startsWith('//')) {
        continue;
      }
      try {
        final s = parse(line, sourceId: sourceId, ordinal: index);
        if (s == null) continue;
        servers.add(s);
        index++;
      } catch (e) {
        failures.add('${_ellipsis(line)} — $e');
      }
    }
    return ParsedLinks(servers: servers, failures: failures);
  }

  /// A subscription body is usually one base64 blob; sometimes it is plain
  /// text. Decoding is attempted and quietly abandoned if the result does not
  /// look like links.
  static String _maybeBase64(String text) {
    if (text.contains('://')) return text;
    try {
      final decoded = utf8.decode(base64.decode(_pad(text.replaceAll(
        RegExp(r'\s'),
        '',
      ))));
      return decoded.contains('://') ? decoded : text;
    } catch (_) {
      return text;
    }
  }

  static String _pad(String s) {
    final normalised = s.replaceAll('-', '+').replaceAll('_', '/');
    final remainder = normalised.length % 4;
    return remainder == 0 ? normalised : normalised + '=' * (4 - remainder);
  }

  static String _ellipsis(String s) =>
      s.length <= 42 ? s : '${s.substring(0, 42)}…';

  /// Parses a single link. Returns null for a line that is not a link at all.
  static ServerConfig? parse(
    String link, {
    required String sourceId,
    int ordinal = 0,
  }) {
    final scheme = link.split('://').first.toLowerCase();
    if (!link.contains('://')) return null;
    if (!supportedSchemes.contains(scheme)) {
      throw FormatException(
          '${scheme.toUpperCase()} links are not supported yet');
    }
    return switch (scheme) {
      'vmess' => _vmess(link, sourceId),
      'vless' => _vless(link, sourceId),
      'trojan' => _trojan(link, sourceId),
      'ss' => _shadowsocks(link, sourceId),
      _ => null,
    };
  }

  // ── vmess ──────────────────────────────────────────────────────────────────

  /// `vmess://<base64 json>` — the original v2rayN format.
  static ServerConfig _vmess(String link, String sourceId) {
    final payload = link.substring('vmess://'.length).trim();
    late final Map<String, dynamic> j;
    try {
      j = jsonDecode(utf8.decode(base64.decode(_pad(payload))))
          as Map<String, dynamic>;
    } catch (_) {
      throw const FormatException('not a valid vmess payload');
    }

    String str(String key, [String fallback = '']) =>
        (j[key] ?? fallback).toString();

    final address = str('add');
    final port = int.tryParse(str('port', '0')) ?? 0;
    final network = str('net', 'tcp');
    final security = str('tls').isEmpty ? 'none' : str('tls');

    final stream = _streamSettings(
      network: network,
      security: security,
      sni: str('sni').isNotEmpty ? str('sni') : str('host'),
      host: str('host'),
      path: str('path', '/'),
      serviceName: str('path'),
      fingerprint: str('fp'),
      alpn: str('alpn'),
      allowInsecure: false,
      address: address,
    );

    return _build(
      sourceId: sourceId,
      name: str('ps', address),
      protocol: 'vmess',
      address: address,
      port: port,
      network: network,
      security: security,
      link: link,
      outbound: {
        'protocol': 'vmess',
        'settings': {
          'vnext': [
            {
              'address': address,
              'port': port,
              'users': [
                {
                  'id': str('id'),
                  'alterId': int.tryParse(str('aid', '0')) ?? 0,
                  'security': str('scy', 'auto'),
                  'level': 0,
                },
              ],
            },
          ],
        },
        'streamSettings': stream,
      },
    );
  }

  // ── vless / trojan / ss share the URI shape ────────────────────────────────

  static ServerConfig _vless(String link, String sourceId) {
    final u = Uri.parse(link);
    final q = u.queryParameters;
    final address = _host(u);
    final network = q['type'] ?? 'tcp';
    final security = q['security'] ?? 'none';

    final stream = _streamSettings(
      network: network,
      security: security,
      sni: q['sni'] ?? q['host'] ?? '',
      host: q['host'] ?? '',
      path: q['path'] ?? '/',
      serviceName: q['serviceName'] ?? '',
      fingerprint: q['fp'] ?? '',
      alpn: q['alpn'] ?? '',
      allowInsecure: q['allowInsecure'] == '1',
      publicKey: q['pbk'] ?? '',
      shortId: q['sid'] ?? '',
      spiderX: q['spx'] ?? '',
      address: address,
    );

    final user = <String, dynamic>{
      'id': Uri.decodeComponent(u.userInfo),
      'encryption': q['encryption'] ?? 'none',
      'level': 0,
    };
    final flow = q['flow'] ?? '';
    if (flow.isNotEmpty) user['flow'] = flow;

    return _build(
      sourceId: sourceId,
      name: _fragment(u, address),
      protocol: 'vless',
      address: address,
      port: u.port,
      network: network,
      security: security,
      link: link,
      outbound: {
        'protocol': 'vless',
        'settings': {
          'vnext': [
            {'address': address, 'port': u.port, 'users': [user]},
          ],
        },
        'streamSettings': stream,
      },
    );
  }

  static ServerConfig _trojan(String link, String sourceId) {
    final u = Uri.parse(link);
    final q = u.queryParameters;
    final address = _host(u);
    final network = q['type'] ?? 'tcp';
    // Trojan is TLS by definition unless the link says otherwise.
    final security = q['security'] ?? 'tls';

    return _build(
      sourceId: sourceId,
      name: _fragment(u, address),
      protocol: 'trojan',
      address: address,
      port: u.port,
      network: network,
      security: security,
      link: link,
      outbound: {
        'protocol': 'trojan',
        'settings': {
          'servers': [
            {
              'address': address,
              'port': u.port,
              'password': Uri.decodeComponent(u.userInfo),
              'level': 0,
            },
          ],
        },
        'streamSettings': _streamSettings(
          network: network,
          security: security,
          sni: q['sni'] ?? q['peer'] ?? '',
          host: q['host'] ?? '',
          path: q['path'] ?? '/',
          serviceName: q['serviceName'] ?? '',
          fingerprint: q['fp'] ?? '',
          alpn: q['alpn'] ?? '',
          allowInsecure: q['allowInsecure'] == '1',
          address: address,
        ),
      },
    );
  }

  /// `ss://` comes in two flavours: the modern
  /// `ss://<base64(method:pass)>@host:port#tag` and the legacy
  /// `ss://<base64(method:pass@host:port)>#tag`.
  static ServerConfig _shadowsocks(String link, String sourceId) {
    final hashIndex = link.indexOf('#');
    final tag = hashIndex < 0
        ? ''
        : Uri.decodeComponent(link.substring(hashIndex + 1));
    final body = (hashIndex < 0 ? link : link.substring(0, hashIndex))
        .substring('ss://'.length);

    String method;
    String password;
    String address;
    int port;

    if (body.contains('@')) {
      final at = body.lastIndexOf('@');
      final creds = body.substring(0, at);
      final hostPart = body.substring(at + 1).split('?').first;
      final decoded = _tryBase64(creds) ?? Uri.decodeComponent(creds);
      final colon = decoded.indexOf(':');
      if (colon < 0) throw const FormatException('missing cipher in ss link');
      method = decoded.substring(0, colon);
      password = decoded.substring(colon + 1);
      (address, port) = _splitHostPort(hostPart);
    } else {
      final decoded = _tryBase64(body.split('?').first);
      if (decoded == null) throw const FormatException('not a valid ss payload');
      final at = decoded.lastIndexOf('@');
      if (at < 0) throw const FormatException('malformed ss link');
      final colon = decoded.indexOf(':');
      method = decoded.substring(0, colon);
      password = decoded.substring(colon + 1, at);
      (address, port) = _splitHostPort(decoded.substring(at + 1));
    }

    return _build(
      sourceId: sourceId,
      name: tag.isEmpty ? address : tag,
      protocol: 'shadowsocks',
      address: address,
      port: port,
      network: 'tcp',
      security: 'none',
      link: link,
      outbound: {
        'protocol': 'shadowsocks',
        'settings': {
          'servers': [
            {
              'address': address,
              'port': port,
              'method': method,
              'password': password,
              'level': 0,
            },
          ],
        },
        'streamSettings': {'network': 'tcp'},
      },
    );
  }

  // ── Shared helpers ─────────────────────────────────────────────────────────

  static (String, int) _splitHostPort(String s) {
    final clean = s.split('/').first.split('?').first;
    final colon = clean.lastIndexOf(':');
    if (colon < 0) return (clean, 0);
    return (clean.substring(0, colon), int.tryParse(clean.substring(colon + 1)) ?? 0);
  }

  static String? _tryBase64(String s) {
    try {
      final out = utf8.decode(base64.decode(_pad(s)));
      return out.contains(':') ? out : null;
    } catch (_) {
      return null;
    }
  }

  static String _host(Uri u) => u.host;

  static String _fragment(Uri u, String fallback) {
    final f = u.fragment.trim();
    if (f.isEmpty) return fallback;
    try {
      return Uri.decodeComponent(f);
    } catch (_) {
      return f;
    }
  }

  /// Builds the Xray `streamSettings` block the config builders expect.
  static Map<String, dynamic> _streamSettings({
    required String network,
    required String security,
    required String sni,
    required String host,
    required String path,
    required String serviceName,
    required String fingerprint,
    required String alpn,
    required bool allowInsecure,
    required String address,
    String publicKey = '',
    String shortId = '',
    String spiderX = '',
  }) {
    final normalisedNetwork = network == 'h2' ? 'http' : network;
    final s = <String, dynamic>{
      'network': normalisedNetwork,
      'security': security == 'none' ? 'none' : security,
    };

    switch (normalisedNetwork) {
      case 'ws':
        s['wsSettings'] = {
          'path': path.isEmpty ? '/' : path,
          if (host.isNotEmpty) 'headers': {'Host': host},
        };
        break;
      case 'grpc':
        s['grpcSettings'] = {
          'serviceName': serviceName.isNotEmpty
              ? serviceName
              : (path.isEmpty ? 'xray' : path.replaceFirst('/', '')),
        };
        break;
      case 'httpupgrade':
        s['httpupgradeSettings'] = {
          'path': path.isEmpty ? '/' : path,
          if (host.isNotEmpty) 'host': host,
        };
        break;
    }

    if (security == 'reality') {
      s['realitySettings'] = {
        'serverName': sni.isNotEmpty ? sni : address,
        'publicKey': publicKey,
        'shortId': shortId,
        'spiderX': spiderX,
        'fingerprint': fingerprint.isEmpty ? 'chrome' : fingerprint,
      };
    } else if (security == 'tls') {
      s['tlsSettings'] = {
        'serverName': sni.isNotEmpty ? sni : address,
        'allowInsecure': allowInsecure,
        if (fingerprint.isNotEmpty) 'fingerprint': fingerprint,
        if (alpn.isNotEmpty) 'alpn': alpn.split(','),
      };
    }
    return s;
  }

  static ServerConfig _build({
    required String sourceId,
    required String name,
    required String protocol,
    required String address,
    required int port,
    required String network,
    required String security,
    required String link,
    required Map<String, dynamic> outbound,
  }) {
    if (address.isEmpty || port == 0) {
      throw const FormatException('missing host or port');
    }
    // Keyed on the endpoint rather than a counter, so re-importing the same
    // subscription keeps the user's rename and hand-placed pin attached to the
    // same server even if the order changed.
    final uid = '$sourceId#$protocol:$address:$port';
    return ServerConfig(
      id: ServerConfig.localId(uid),
      uid: uid,
      sourceId: sourceId,
      tag: name,
      name: name,
      region: '',
      // Deliberately blank: a share link says nothing about geography, and
      // guessing from the hostname would put pins in the wrong country. The
      // user places these by hand.
      country: '',
      protocol: protocol,
      transport: network,
      network: network,
      security: security,
      address: address,
      port: port,
      link: link,
      outbound: outbound,
    );
  }
}

/// Outcome of importing a blob of links.
class ParsedLinks {
  const ParsedLinks({required this.servers, required this.failures});

  final List<ServerConfig> servers;

  /// One line per link we could not read, already worded for display.
  final List<String> failures;

  bool get isEmpty => servers.isEmpty;
  int get count => servers.length;
}
