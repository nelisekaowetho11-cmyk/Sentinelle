import 'dart:convert';

import '../models/models.dart';
import 'routing.dart';

/// One application group pinned to its own exit.
class AppRoute {
  const AppRoute({required this.processes, required this.server});

  /// Executable names as the OS reports them (`chrome.exe`, `firefox`).
  final List<String> processes;
  final ServerConfig server;
}

enum TunnelMode {
  /// Local SOCKS/HTTP proxy only. No driver, no elevation.
  proxy,

  /// System-wide TUN device — every app on the machine is routed.
  /// Needs administrator/root.
  vpn,
}

/// Builds a sing-box config from the outbound the panel hands us.
///
/// Targets the sing-box 1.12+ schema: new-style DNS servers (`type`/`server`),
/// `route.default_domain_resolver` instead of outbound DNS rule items, and
/// rule `action`s instead of the removed `block`/`dns` outbound types.
class SingBoxConfigBuilder {
  const SingBoxConfigBuilder({
    required this.mode,
    required this.socksPort,
    required this.httpPort,
    required this.dnsServers,
    required this.bypassLan,
    required this.blockAds,
    this.splitMode = SplitMode.all,
    this.splitApps = const [],
    this.forceTunnel = const RoutingRules(domains: [], ips: []),
    this.forceDirect = const RoutingRules(domains: [], ips: []),
    this.clashApiPort,
    this.tunMtu = 9000,
    this.dnsGuard = true,
    this.ipv6Guard = true,
    this.webRtcGuard = true,
    this.lanGuard = true,
    this.quicGuard = false,
    this.appRoutes = const [],
  });

  /// Applications pinned to a location of their own.
  ///
  /// Each becomes an extra outbound plus a `process_name` rule, so one core
  /// carries several destinations at once. sing-box resolves the owning
  /// process of every connection, which is what makes per-app routing work in
  /// TUN mode *and* through the local proxy inbounds.
  final List<AppRoute> appRoutes;

  /// Force every lookup through the tunnel's resolver.
  final bool dnsGuard;

  /// Refuse IPv6 rather than let it slip past a v4-only tunnel.
  final bool ipv6Guard;

  /// Block the STUN/TURN discovery WebRTC uses to learn the real address.
  final bool webRtcGuard;

  /// Drop local-network discovery (mDNS, LLMNR, SSDP, NetBIOS), which
  /// announces the device by name to the network it is sitting on.
  final bool lanGuard;

  /// Refuse QUIC so browsers fall back to TCP through the tunnel.
  final bool quicGuard;

  /// See [XrayConfigBuilder] — same endpoints, same reasoning.
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

  final TunnelMode mode;
  final int socksPort;
  final int httpPort;
  final List<String> dnsServers;
  final bool bypassLan;
  final bool blockAds;

  /// Per-application routing. sing-box matches on the executable name, so
  /// entries look like `chrome.exe` on Windows and `firefox` elsewhere.
  final SplitMode splitMode;
  final List<String> splitApps;

  /// User-supplied domain/IP rules.
  final RoutingRules forceTunnel;
  final RoutingRules forceDirect;

  /// When set, the Clash-compatible API is exposed so the app can read live
  /// traffic counters over a websocket-free HTTP poll.
  final int? clashApiPort;
  final int tunMtu;

  static const _tunAddress = '172.19.0.1/30';

  Map<String, dynamic> build(ServerConfig server) {
    final proxy = _outbound(server);

    final inbounds = <Map<String, dynamic>>[];
    if (mode == TunnelMode.vpn) {
      inbounds.add({
        'type': 'tun',
        'tag': 'tun-in',
        'address': [_tunAddress],
        'mtu': tunMtu,
        'auto_route': true,
        'strict_route': true,
        'stack': 'mixed',
      });
    }
    // Always present: it is how the app itself checks the core is alive, and
    // it keeps proxy-mode consumers working even in VPN mode.
    inbounds.add({
      'type': 'mixed',
      'tag': 'mixed-in',
      'listen': '127.0.0.1',
      'listen_port': socksPort,
    });
    if (httpPort != socksPort) {
      inbounds.add({
        'type': 'mixed',
        'tag': 'http-in',
        'listen': '127.0.0.1',
        'listen_port': httpPort,
      });
    }

    final rules = <Map<String, dynamic>>[
      {'action': 'sniff'},
      // Every DNS query the machine makes is answered by the core, whichever
      // resolver the application was configured with. This is the DNS leak
      // guard: without it, an app that talks straight to 8.8.8.8 tells the
      // network exactly what it is resolving.
      {'protocol': 'dns', 'action': 'hijack-dns'},
    ];
    if (webRtcGuard) {
      rules.add({'domain_suffix': _stunDomains, 'action': 'reject'});
      rules.add({
        'network': 'udp',
        'port_range': ['3478:3478', '5349:5349', '19302:19309'],
        'action': 'reject',
      });
    }
    if (lanGuard) {
      rules.add({
        'port': const [137, 138, 139, 1900, 5353, 5355],
        'action': 'reject',
      });
      rules.add({
        'ip_cidr': const ['224.0.0.0/4', '255.255.255.255/32', 'ff00::/8'],
        'action': 'reject',
      });
    }
    if (quicGuard) {
      rules.add({'network': 'udp', 'port': 443, 'action': 'reject'});
    }
    if (ipv6Guard) {
      rules.add({'ip_version': 6, 'action': 'reject'});
    }
    if (dnsGuard) {
      // Belt and braces with hijack-dns: anything still aimed at port 53 goes
      // through the tunnel rather than out of the local interface.
      rules.add({'network': 'udp', 'port': 53, 'outbound': 'proxy'});
    }
    if (blockAds) {
      rules.add({
        'domain_keyword': const [
          'doubleclick',
          'googlesyndication',
          'googleadservices',
          'adservice',
          'adnxs',
        ],
        'action': 'reject',
      });
    }
    if (bypassLan) {
      rules.add({'ip_is_private': true, 'outbound': 'direct'});
    }

    // User rules come before the app split so an explicit domain/IP always
    // wins over a blanket per-app decision.
    if (forceDirect.domains.isNotEmpty) {
      rules.add({'domain_suffix': forceDirect.domains, 'outbound': 'direct'});
    }
    if (forceDirect.ips.isNotEmpty) {
      rules.add({'ip_cidr': forceDirect.ips, 'outbound': 'direct'});
    }
    if (forceTunnel.domains.isNotEmpty) {
      rules.add({'domain_suffix': forceTunnel.domains, 'outbound': 'proxy'});
    }
    if (forceTunnel.ips.isNotEmpty) {
      rules.add({'ip_cidr': forceTunnel.ips, 'outbound': 'proxy'});
    }

    // Per-app tunnels win over the blanket split: naming an app's own exit is
    // a more specific instruction than "these apps use the tunnel".
    final extraOutbounds = <Map<String, dynamic>>[];
    for (var i = 0; i < appRoutes.length; i++) {
      final route = appRoutes[i];
      final names =
          route.processes.where((p) => p.trim().isNotEmpty).toList();
      if (names.isEmpty) continue;
      final tag = 'proxy-app-$i';
      extraOutbounds.add(_outbound(route.server, tag: tag));
      rules.add({'process_name': names, 'outbound': tag});
    }

    final apps = splitApps.where((a) => a.trim().isNotEmpty).toList();
    if (apps.isNotEmpty && splitMode == SplitMode.exceptListed) {
      rules.add({'process_name': apps, 'outbound': 'direct'});
    } else if (apps.isNotEmpty && splitMode == SplitMode.onlyListed) {
      rules.add({'process_name': apps, 'outbound': 'proxy'});
    }

    final dns = dnsServers.isEmpty ? const ['1.1.1.1', '8.8.8.8'] : dnsServers;
    final config = <String, dynamic>{
      'log': {'level': 'warn', 'timestamp': true},
      'dns': {
        'servers': [
          {
            'tag': 'remote',
            'type': 'udp',
            'server': dns.first,
            'detour': 'proxy',
          },
          {
            'tag': 'local',
            'type': 'udp',
            'server': dns.length > 1 ? dns[1] : '8.8.8.8',
            // No detour: sing-box refuses "detour to an empty direct
            // outbound", and direct is the default route anyway.
          },
        ],
        'final': 'remote',
        // ipv4_only is the load-bearing half of the IPv6 guard: with no AAAA
        // answers, almost nothing attempts a v6 route the tunnel cannot carry.
        'strategy': ipv6Guard ? 'ipv4_only' : 'prefer_ipv4',
      },
      'inbounds': inbounds,
      'outbounds': [
        proxy,
        ...extraOutbounds,
        {'type': 'direct', 'tag': 'direct'},
      ],
      'route': {
        'auto_detect_interface': true,
        // In "only these apps" mode everything else must go direct, so the
        // fallback flips and the per-app rule above is what selects the tunnel.
        'final': (splitApps.isNotEmpty && splitMode == SplitMode.onlyListed)
            ? 'direct'
            : 'proxy',
        'default_domain_resolver': {'server': 'local'},
        'rules': rules,
      },
    };

    if (clashApiPort != null) {
      config['experimental'] = {
        'clash_api': {
          'external_controller': '127.0.0.1:$clashApiPort',
        },
      };
    }

    return config;
  }

  String buildJson(ServerConfig server) =>
      const JsonEncoder.withIndent('  ').convert(build(server));

  // ── Outbound translation ───────────────────────────────────────────────────

  Map<String, dynamic> _outbound(ServerConfig server, {String tag = 'proxy'}) {
    final x = server.outbound;
    final stream = Map<String, dynamic>.from(
        (x['streamSettings'] as Map?) ?? const {});
    final settings = Map<String, dynamic>.from((x['settings'] as Map?) ?? const {});
    final proto = (x['protocol'] as String? ?? server.protocol).toLowerCase();

    final address = server.address;
    final port = server.port;

    final ob = <String, dynamic>{
      'tag': tag,
      'server': address,
      'server_port': port,
    };

    switch (proto) {
      case 'vless':
        final user = _firstUser(settings);
        ob['type'] = 'vless';
        ob['uuid'] = (user['id'] ?? '') as String;
        final flow = (user['flow'] as String?) ?? '';
        if (flow.isNotEmpty) ob['flow'] = flow;
        break;
      case 'vmess':
        final user = _firstUser(settings);
        ob['type'] = 'vmess';
        ob['uuid'] = (user['id'] ?? '') as String;
        ob['security'] = (user['security'] as String?) ?? 'auto';
        ob['alter_id'] = (user['alterId'] as int?) ?? 0;
        break;
      case 'trojan':
        final s = _firstServer(settings);
        ob['type'] = 'trojan';
        ob['password'] = (s['password'] ?? '') as String;
        break;
      case 'shadowsocks':
        final s = _firstServer(settings);
        ob['type'] = 'shadowsocks';
        ob['method'] = (s['method'] ?? 'chacha20-ietf-poly1305') as String;
        ob['password'] = (s['password'] ?? '') as String;
        break;
      default:
        throw UnsupportedError('Protocol "$proto" is not supported in VPN mode');
    }

    final tls = _tls(stream, address);
    if (tls != null) ob['tls'] = tls;

    final transport = _transport(stream);
    if (transport != null) ob['transport'] = transport;

    return ob;
  }

  Map<String, dynamic> _firstUser(Map<String, dynamic> settings) {
    final vnext = settings['vnext'] as List?;
    if (vnext == null || vnext.isEmpty) return const {};
    final users = (vnext.first as Map)['users'] as List?;
    if (users == null || users.isEmpty) return const {};
    return Map<String, dynamic>.from(users.first as Map);
  }

  Map<String, dynamic> _firstServer(Map<String, dynamic> settings) {
    final servers = settings['servers'] as List?;
    if (servers == null || servers.isEmpty) return const {};
    return Map<String, dynamic>.from(servers.first as Map);
  }

  Map<String, dynamic>? _tls(Map<String, dynamic> stream, String fallbackSni) {
    final security = (stream['security'] as String?) ?? 'none';
    if (security == 'reality') {
      final r = Map<String, dynamic>.from(
          (stream['realitySettings'] as Map?) ?? const {});
      return {
        'enabled': true,
        'server_name': (r['serverName'] as String?)?.isNotEmpty == true
            ? r['serverName']
            : fallbackSni,
        'utls': {
          'enabled': true,
          'fingerprint': (r['fingerprint'] as String?) ?? 'chrome',
        },
        'reality': {
          'enabled': true,
          'public_key': (r['publicKey'] as String?) ?? '',
          'short_id': (r['shortId'] as String?) ?? '',
        },
      };
    }
    if (security == 'tls') {
      final t = Map<String, dynamic>.from(
          (stream['tlsSettings'] as Map?) ?? const {});
      final tls = <String, dynamic>{
        'enabled': true,
        'server_name': (t['serverName'] as String?)?.isNotEmpty == true
            ? t['serverName']
            : fallbackSni,
        'insecure': (t['allowInsecure'] as bool?) ?? false,
      };
      final fp = t['fingerprint'] as String?;
      if (fp != null && fp.isNotEmpty) {
        tls['utls'] = {'enabled': true, 'fingerprint': fp};
      }
      final alpn = t['alpn'];
      if (alpn is List && alpn.isNotEmpty) tls['alpn'] = alpn;
      return tls;
    }
    return null;
  }

  Map<String, dynamic>? _transport(Map<String, dynamic> stream) {
    final network = (stream['network'] as String?) ?? 'tcp';
    switch (network) {
      case 'ws':
        final ws = Map<String, dynamic>.from(
            (stream['wsSettings'] as Map?) ?? const {});
        final t = <String, dynamic>{
          'type': 'ws',
          'path': (ws['path'] as String?) ?? '/',
        };
        final host = ws['host'] as String? ??
            ((ws['headers'] as Map?)?['Host'] as String?);
        if (host != null && host.isNotEmpty) {
          t['headers'] = {'Host': host};
        }
        return t;
      case 'grpc':
        final g = Map<String, dynamic>.from(
            (stream['grpcSettings'] as Map?) ?? const {});
        return {
          'type': 'grpc',
          'service_name': (g['serviceName'] as String?) ?? 'xray',
        };
      case 'httpupgrade':
        final h = Map<String, dynamic>.from(
            (stream['httpupgradeSettings'] as Map?) ?? const {});
        final t = <String, dynamic>{
          'type': 'httpupgrade',
          'path': (h['path'] as String?) ?? '/',
        };
        final host = h['host'] as String?;
        if (host != null && host.isNotEmpty) t['host'] = host;
        return t;
      case 'tcp':
      case 'raw':
        return null;
      default:
        // xhttp / kcp have no sing-box equivalent — the caller falls back
        // to the Xray core for those.
        throw UnsupportedError(
            'Transport "$network" is not supported in VPN mode — '
            'switch this connection to proxy mode.');
    }
  }

  /// True when sing-box can carry this server at all.
  static bool supports(ServerConfig s) {
    const okProtocols = {'vless', 'vmess', 'trojan', 'shadowsocks'};
    const okNetworks = {'tcp', 'raw', 'ws', 'grpc', 'httpupgrade'};
    return okProtocols.contains(s.protocol.toLowerCase()) &&
        okNetworks.contains(s.network.toLowerCase());
  }
}
