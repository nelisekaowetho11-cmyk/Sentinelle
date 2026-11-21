import 'dart:convert';

import '../models/models.dart';
import 'routing.dart';

/// Builds the complete Xray configuration used by flutter_v2ray.
///
/// Important:
/// - The main VPN outbound stays at outbounds[0].
/// - DNS servers remain plain strings.
/// - Optional HTTP/SOCKS5 proxy chaining uses streamSettings.sockopt.dialerProxy.
/// - Payload templates are translated to WebSocket/HTTPUpgrade headers.
/// - Arbitrary raw CONNECT payload injection is not supported by Xray here.
class XrayConfigBuilder {
  const XrayConfigBuilder({
    required this.socksPort,
    required this.httpPort,
    required this.dnsServers,
    required this.bypassLan,
    required this.blockAds,
    this.forceTunnel = const RoutingRules(domains: [], ips: []),
    this.forceDirect = const RoutingRules(domains: [], ips: []),
    this.apiPort,
    this.dnsGuard = true,
    this.ipv6Guard = true,
    this.webRtcGuard = true,
    this.lanGuard = true,
    this.quicGuard = false,
  });

  final bool dnsGuard;
  final bool ipv6Guard;
  final bool webRtcGuard;
  final bool lanGuard;
  final bool quicGuard;

  final int socksPort;
  final int httpPort;
  final List<String> dnsServers;
  final bool bypassLan;
  final bool blockAds;

  final RoutingRules forceTunnel;
  final RoutingRules forceDirect;

  final int? apiPort;

  static const privateRanges = <String>[
    '0.0.0.0/8',
    '10.0.0.0/8',
    '100.64.0.0/10',
    '127.0.0.0/8',
    '169.254.0.0/16',
    '172.16.0.0/12',
    '192.0.0.0/24',
    '192.168.0.0/16',
    '198.18.0.0/15',
    '224.0.0.0/4',
    '240.0.0.0/4',
    '::1/128',
    'fc00::/7',
    'fe80::/10',
  ];

  static const _stunDomains = <String>[
    'stun.l.google.com',
    'stun1.l.google.com',
    'stun2.l.google.com',
    'stun3.l.google.com',
    'stun4.l.google.com',
    'stun.services.mozilla.com',
    'stun.cloudflare.com',
    'global.stun.twilio.com',
  ];

  static const _stunPorts = '3478,5349,19302-19309';
  static const lanDiscoveryPorts = '137-139,1900,5353,5355';

  static const lanDiscoveryIps = <String>[
    '224.0.0.0/4',
    '255.255.255.255/32',
    'ff00::/8',
  ];

  static const _adKeywords = <String>[
    'doubleclick',
    'googlesyndication',
    'googleadservices',
    'adservice',
    'adnxs',
    'scorecardresearch',
  ];

  static const _upstreamProxyTag = 'panel-upstream-proxy';

  Map<String, dynamic> build(ServerConfig server) {
    final proxy = Map<String, dynamic>.from(server.outbound);
    proxy['tag'] = 'proxy';

    // Apply supported HTTP-style payload headers before building outbounds.
    _applyPayload(proxy, server);

    // Build an optional upstream HTTP or SOCKS5 proxy.
    final upstreamProxy = _buildUpstreamProxy(server);

    if (upstreamProxy != null) {
      _attachDialerProxy(proxy, _upstreamProxyTag);
    }

    final inbounds = <Map<String, dynamic>>[
      {
        'tag': 'socks-in',
        'port': socksPort,
        'listen': '127.0.0.1',
        'protocol': 'socks',
        'settings': {
          'auth': 'noauth',
          'udp': true,
          'userLevel': 0,
        },
        'sniffing': {
          'enabled': true,
          'destOverride': ['http', 'tls'],
          'routeOnly': false,
        },
      },
      {
        'tag': 'http-in',
        'port': httpPort,
        'listen': '127.0.0.1',
        'protocol': 'http',
        'settings': {'userLevel': 0},
        'sniffing': {
          'enabled': true,
          'destOverride': ['http', 'tls'],
          'routeOnly': false,
        },
      },
    ];

    final rules = <Map<String, dynamic>>[];

    if (apiPort != null) {
      inbounds.add({
        'tag': 'api-in',
        'port': apiPort,
        'listen': '127.0.0.1',
        'protocol': 'dokodemo-door',
        'settings': {'address': '127.0.0.1'},
      });

      rules.add({
        'type': 'field',
        'inboundTag': ['api-in'],
        'outboundTag': 'api',
      });
    }

    // Guards are evaluated before user routing rules.
    if (webRtcGuard) {
      rules.add({
        'type': 'field',
        'domain': _stunDomains,
        'outboundTag': 'block',
      });

      rules.add({
        'type': 'field',
        'port': _stunPorts,
        'network': 'udp',
        'outboundTag': 'block',
      });
    }

    if (lanGuard) {
      rules.add({
        'type': 'field',
        'port': lanDiscoveryPorts,
        'outboundTag': 'block',
      });

      rules.add({
        'type': 'field',
        'ip': lanDiscoveryIps,
        'outboundTag': 'block',
      });
    }

    if (quicGuard) {
      rules.add({
        'type': 'field',
        'port': '443',
        'network': 'udp',
        'outboundTag': 'block',
      });
    }

    if (ipv6Guard) {
      rules.add({
        'type': 'field',
        'ip': ['::/0'],
        'outboundTag': 'block',
      });
    }

    if (dnsGuard) {
      rules.add({
        'type': 'field',
        'port': '53',
        'outboundTag': 'proxy',
      });
    }

    if (blockAds) {
      rules.add({
        'type': 'field',
        'domain': _adKeywords,
        'outboundTag': 'block',
      });
    }

    if (bypassLan) {
      rules.add({
        'type': 'field',
        'ip': privateRanges,
        'outboundTag': 'direct',
      });
    }

    if (forceDirect.domains.isNotEmpty) {
      rules.add({
        'type': 'field',
        'domain': forceDirect.domains.map((d) => 'domain:$d').toList(),
        'outboundTag': 'direct',
      });
    }

    if (forceDirect.ips.isNotEmpty) {
      rules.add({
        'type': 'field',
        'ip': forceDirect.ips,
        'outboundTag': 'direct',
      });
    }

    if (forceTunnel.domains.isNotEmpty) {
      rules.add({
        'type': 'field',
        'domain': forceTunnel.domains.map((d) => 'domain:$d').toList(),
        'outboundTag': 'proxy',
      });
    }

    if (forceTunnel.ips.isNotEmpty) {
      rules.add({
        'type': 'field',
        'ip': forceTunnel.ips,
        'outboundTag': 'proxy',
      });
    }

    final dns =
        dnsServers.isEmpty ? const ['1.1.1.1', '8.8.8.8'] : dnsServers;

    // Keep the main VPN outbound first. The upstream proxy is additional;
    // it must not replace the main outbound used by the app's display logic.
    final outbounds = <Map<String, dynamic>>[
      proxy,
      if (upstreamProxy != null) upstreamProxy,
      {
        'tag': 'direct',
        'protocol': 'freedom',
        'settings': {
          'domainStrategy': ipv6Guard ? 'UseIPv4' : 'AsIs',
        },
      },
      {
        'tag': 'block',
        'protocol': 'blackhole',
        'settings': {
          'response': {'type': 'http'},
        },
      },
    ];

    final config = <String, dynamic>{
      'log': {'loglevel': 'warning'},
      'dns': {
        'servers': dns,
        if (ipv6Guard) 'queryStrategy': 'UseIPv4',
      },
      'inbounds': inbounds,
      'outbounds': outbounds,
      'routing': {
        'domainStrategy': 'AsIs',
        'rules': rules,
      },
    };

    if (apiPort != null) {
      config['stats'] = <String, dynamic>{};

      config['api'] = {
        'tag': 'api',
        'services': ['StatsService'],
      };

      config['policy'] = {
        'levels': {
          '0': {
            'statsUserUplink': true,
            'statsUserDownlink': true,
          },
        },
        'system': {
          'statsOutboundUplink': true,
          'statsOutboundDownlink': true,
        },
      };
    }

    return config;
  }

  /// Creates an HTTP or SOCKS5 upstream proxy outbound.
  ///
  /// If the panel has not supplied proxy_type, HTTP is the default.
  /// Set client_options.proxy_type to "socks5" for a SOCKS5 endpoint.
  Map<String, dynamic>? _buildUpstreamProxy(ServerConfig server) {
    final host = server.proxyIp.trim();
    final port = server.proxyPort;

    if (host.isEmpty && port == null) {
      return null;
    }

    if (host.isEmpty || port == null) {
      throw const FormatException(
        'Proxy configuration is incomplete. Enter both proxy IP/host and port.',
      );
    }

    if (port < 1 || port > 65535) {
      throw const FormatException(
        'Proxy port must be between 1 and 65535.',
      );
    }

    final options = _map(server.clientOptions);
    final nestedProxy = _map(
      options['proxy'] ?? options['proxy_config'],
    );

    final requestedType = _firstText([
      options['proxy_type'],
      options['proxyType'],
      nestedProxy['type'],
      nestedProxy['protocol'],
    ]).toLowerCase();

    final type = requestedType.isEmpty ? 'http' : requestedType;

    final protocol = switch (type) {
      'http' || 'https' => 'http',
      'socks' || 'socks5' => 'socks',
      _ => throw FormatException(
          'Unsupported proxy type "$type". Use HTTP or SOCKS5.',
        ),
    };

    final username = _firstText([
      options['proxy_username'],
      options['proxy_user'],
      nestedProxy['username'],
      nestedProxy['user'],
    ]);

    final password = _firstText([
      options['proxy_password'],
      nestedProxy['password'],
      nestedProxy['pass'],
    ]);

    final settings = <String, dynamic>{
      'address': host,
      'port': port,
    };

    // Include credentials only when a username is present.
    if (username.isNotEmpty) {
      settings['user'] = username;
      settings['pass'] = password;
    }

    return {
      'tag': _upstreamProxyTag,
      'protocol': protocol,
      'settings': settings,
    };
  }

  /// Makes the main VPN server connect through the upstream proxy.
  ///
  /// Current Xray uses streamSettings.sockopt.dialerProxy for this.
  void _attachDialerProxy(
    Map<String, dynamic> outbound,
    String dialerTag,
  ) {
    final streamSettings = _map(outbound['streamSettings']);
    final sockopt = _map(streamSettings['sockopt']);

    sockopt['dialerProxy'] = dialerTag;

    streamSettings['sockopt'] = sockopt;
    outbound['streamSettings'] = streamSettings;
  }

  /// Applies a header-style payload to WebSocket or HTTPUpgrade.
  ///
  /// Supported examples:
  ///
  /// GET /path HTTP/1.1[crlf]
  /// Host: example.com[crlf]
  /// X-Custom: value[crlf]
  ///
  /// Or simply:
  ///
  /// Host: example.com[crlf]
  /// X-Custom: value
  ///
  /// Xray creates the actual HTTP/WebSocket handshake. This method maps
  /// the supplied path and headers into Xray's transport configuration.
  void _applyPayload(
    Map<String, dynamic> outbound,
    ServerConfig server,
  ) {
    final payload = server.payload.trim();

    if (payload.isEmpty) {
      return;
    }

    final streamSettings = _map(outbound['streamSettings']);
    final network = _getNetwork(server, streamSettings);

    final settingsKey = switch (network) {
      'ws' => 'wsSettings',
      'httpupgrade' => 'httpupgradeSettings',
      _ => throw FormatException(
          'Payload was supplied, but the server transport is "$network". '
          'This builder supports header-style payloads only for '
          'WebSocket and HTTPUpgrade.',
        ),
    };

    final parsed = _parsePayload(payload, server);
    final transportSettings = _map(streamSettings[settingsKey]);
    final existingHeaders = _map(transportSettings['headers']);

    final payloadHeaders = _map(parsed['headers']);

    // Merge headers case-insensitively. Payload values replace existing ones.
    for (final entry in payloadHeaders.entries) {
      final oldKey = existingHeaders.keys.cast<String?>().firstWhere(
            (key) => key?.toLowerCase() == entry.key.toLowerCase(),
            orElse: () => null,
          );

      if (oldKey != null) {
        existingHeaders.remove(oldKey);
      }

      existingHeaders[entry.key] = entry.value;
    }

    final path = parsed['path'] as String?;
    final host = parsed['host'] as String?;

    if (path != null && path.isNotEmpty) {
      transportSettings['path'] = path;
    }

    if (host != null && host.isNotEmpty) {
      transportSettings['host'] = host;
    }

    if (existingHeaders.isNotEmpty) {
      transportSettings['headers'] = existingHeaders;
    }

    streamSettings[settingsKey] = transportSettings;
    outbound['streamSettings'] = streamSettings;
  }

  String _getNetwork(
    ServerConfig server,
    Map<String, dynamic> streamSettings,
  ) {
    final candidates = [
      streamSettings['network'],
      server.network,
      server.transport,
    ];

    String? fallback;

    for (final candidate in candidates) {
      final normalized = _normalizeNetwork(candidate);

      if (normalized.isEmpty) continue;

      fallback ??= normalized;

      if (normalized != 'tcp') {
        return normalized;
      }
    }

    return fallback ?? 'tcp';
  }

  String _normalizeNetwork(dynamic value) {
    final text = value?.toString().trim().toLowerCase() ?? '';

    return switch (text) {
      'websocket' || 'web-socket' || 'ws' => 'ws',
      'http_upgrade' || 'http-upgrade' || 'httpupgrade' => 'httpupgrade',
      'raw' || 'tcp' || 'none' => 'tcp',
      _ => text,
    };
  }

  Map<String, dynamic> _parsePayload(
    String rawPayload,
    ServerConfig server,
  ) {
    final hostPort = '${server.address}:${server.port}';

    var text = rawPayload
        .replaceAll(
          RegExp(r'\[crlf\]', caseSensitive: false),
          '\n',
        )
        .replaceAll(
          RegExp(r'\[lf\]', caseSensitive: false),
          '\n',
        )
        .replaceAll(r'\r\n', '\n')
        .replaceAll(r'\n', '\n')
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n')
        .replaceAll(
          RegExp(r'%0d%0a', caseSensitive: false),
          '\n',
        );

    // Common placeholders used in HTTP-style payload templates.
    text = text
        .replaceAll(
          RegExp(r'\[host_port\]', caseSensitive: false),
          hostPort,
        )
        .replaceAll(
          RegExp(r'\[host\]', caseSensitive: false),
          server.address,
        )
        .replaceAll(
          RegExp(r'\[port\]', caseSensitive: false),
          server.port.toString(),
        );

    final headers = <String, dynamic>{};
    String? path;
    String? host;

    final lines = text.split('\n');

    final requestLinePattern = RegExp(
      r'^(GET|POST|HEAD|PUT|OPTIONS|CONNECT)\s+(\S+)\s+HTTP/1\.[01]$',
      caseSensitive: false,
    );

    final headerNamePattern = RegExp(
      r"^[A-Za-z0-9!#$%&'*+.^_`|~-]+$",
    );

    for (final originalLine in lines) {
      final line = originalLine.trim();

      if (line.isEmpty) continue;

      final requestMatch = requestLinePattern.firstMatch(line);

      if (requestMatch != null) {
        final method = requestMatch.group(1)!.toUpperCase();
        final target = requestMatch.group(2)!;

        if (method == 'CONNECT') {
          throw const FormatException(
            'Raw CONNECT payloads cannot be injected by this Xray '
            'transport builder. Use a supported WebSocket or '
            'HTTPUpgrade header-style payload instead.',
          );
        }

        if (target.startsWith('/')) {
          path = target;
        } else {
          final uri = Uri.tryParse(target);

          if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
            throw const FormatException(
              'Payload request line must use a valid HTTP path.',
            );
          }

          path = uri.path.isEmpty ? '/' : uri.path;

          if (uri.hasQuery) {
            path = '$path?${uri.query}';
          }
        }

        continue;
      }

      final colon = line.indexOf(':');

      if (colon <= 0) {
        throw FormatException(
          'Payload line is not a valid HTTP header: "$line"',
        );
      }

      final name = line.substring(0, colon).trim();
      final value = line.substring(colon + 1).trim();

      if (!headerNamePattern.hasMatch(name)) {
        throw FormatException(
          'Payload contains an invalid HTTP header name: "$name"',
        );
      }

      if (value.contains('\n') || value.contains('\r')) {
        throw const FormatException(
          'Payload header values cannot contain line breaks.',
        );
      }

      final lowerName = name.toLowerCase();

      if (lowerName == 'host') {
        host = value;
        continue;
      }

      // Xray generates the protocol handshake headers itself.
      // Do not override these because that can break the handshake.
      const generatedHeaders = {
        'connection',
        'upgrade',
        'sec-websocket-key',
        'sec-websocket-version',
        'sec-websocket-extensions',
        'sec-websocket-protocol',
      };

      if (generatedHeaders.contains(lowerName)) {
        continue;
      }

      headers[name] = value;
    }

    if (headers.isEmpty && host == null && path == null) {
      throw const FormatException(
        'Payload did not contain a usable HTTP path or header.',
      );
    }

    return {
      'headers': headers,
      'path': path,
      'host': host,
    };
  }

  Map<String, dynamic> _map(dynamic value) {
    if (value is! Map) {
      return <String, dynamic>{};
    }

    final result = <String, dynamic>{};

    value.forEach((key, item) {
      if (key != null) {
        result[key.toString()] = item;
      }
    });

    return result;
  }

  String _firstText(List<dynamic> values) {
    for (final value in values) {
      if (value == null) continue;

      final text = value.toString().trim();

      if (text.isNotEmpty) {
        return text;
      }
    }

    return '';
  }

  String buildJson(ServerConfig server) =>
      const JsonEncoder.withIndent('  ').convert(build(server));
}
