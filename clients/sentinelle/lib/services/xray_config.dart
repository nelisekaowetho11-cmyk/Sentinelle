import 'dart:convert';

import '../models/models.dart';
import 'routing.dart';

/// Turns the panel-provided outbound into a complete Xray config.
///
/// Used by the Android engine (`flutter_v2ray`). Two constraints come from the
/// plugin and must not be broken:
///   * `outbounds[0]` is read for the display address, so the proxy stays first;
///   * `dns.servers` must be an array of plain strings — the plugin feeds them
///     to `VpnService.Builder.addDnsServer`, and an object there throws, which
///     leaves the tunnel with no DNS at all.
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

  /// Force every lookup through the tunnel's resolver.
  final bool dnsGuard;

  /// Refuse IPv6 rather than let it slip past a v4-only tunnel.
  final bool ipv6Guard;

  /// Block the STUN/TURN discovery WebRTC uses to learn the real address.
  final bool webRtcGuard;

  /// Drop local-network discovery, which announces the device by name.
  final bool lanGuard;

  /// Refuse QUIC so browsers fall back to TCP through the tunnel.
  final bool quicGuard;

  final int socksPort;
  final int httpPort;
  final List<String> dnsServers;
  final bool bypassLan;
  final bool blockAds;

  /// User-supplied domain/IP rules. Per-app splitting on Android is done by the
  /// VpnService itself (disallowed packages), not by these routing rules.
  final RoutingRules forceTunnel;
  final RoutingRules forceDirect;

  /// When set, a dokodemo-door API inbound is added for live traffic counters.
  final int? apiPort;

  /// Explicit CIDRs instead of `geoip:private`, so routing never depends on a
  /// geoip.dat being present and readable next to the core.
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

  /// Hosts WebRTC uses for address discovery. Blocking the well-known STUN
  /// providers by name catches the clients that hard-code them, and the port
  /// rule below catches the rest.
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

  /// STUN/TURN: 3478 and 5349 are the registered pair, 19302-19309 is
  /// Google's block.
  static const _stunPorts = '3478,5349,19302-19309';

  /// Local discovery: mDNS, LLMNR, SSDP/UPnP and the NetBIOS trio. Each of
  /// these puts the device's real hostname — and often its addresses — on the
  /// wire for anything on the same network to collect.
  static const lanDiscoveryPorts = '137-139,1900,5353,5355';

  /// Multicast and broadcast ranges those protocols speak to.
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

  Map<String, dynamic> build(ServerConfig server) {
    final proxy = Map<String, dynamic>.from(server.outbound);
    proxy['tag'] = 'proxy';

    final inbounds = <Map<String, dynamic>>[
      {
        'tag': 'socks-in',
        'port': socksPort,
        'listen': '127.0.0.1',
        'protocol': 'socks',
        'settings': {'auth': 'noauth', 'udp': true, 'userLevel': 0},
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

    // Guards come first: nothing a user rule says should be able to hand
    // traffic to an outbound that leaks.
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
      // Blocked outright rather than sent direct: the point is that these
      // never reach the local network, not that they avoid the tunnel.
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
      // QUIC is UDP/443. Refusing it makes browsers fall back to TCP, which
      // the tunnel carries reliably.
      rules.add({
        'type': 'field',
        'port': '443',
        'network': 'udp',
        'outboundTag': 'block',
      });
    }
    if (ipv6Guard) {
      // Anything that did reach the tunnel over v6 is dropped rather than
      // forwarded. The bigger half of this guard is `queryStrategy` below:
      // with no AAAA answers, almost nothing tries v6 in the first place.
      rules.add({
        'type': 'field',
        'ip': ['::/0'],
        'outboundTag': 'block',
      });
    }
    if (dnsGuard) {
      // Every lookup goes out of the proxy, whichever resolver an app picked.
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

    // Explicit user rules, most specific intent first.
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

    final dns = dnsServers.isEmpty ? const ['1.1.1.1', '8.8.8.8'] : dnsServers;

    final config = <String, dynamic>{
      'log': {'loglevel': 'warning'},
      // Plain strings only — see the class doc.
      'dns': {
        'servers': dns,
        // The load-bearing half of the IPv6 guard: with no AAAA answers,
        // applications never try a v6 route that the tunnel cannot carry.
        if (ipv6Guard) 'queryStrategy': 'UseIPv4',
      },
      'inbounds': inbounds,
      'outbounds': [
        proxy,
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
      ],
      'routing': {
        // AsIs, deliberately. IPIfNonMatch makes Xray resolve every hostname
        // through its own DNS client before routing; those lookups go out over
        // the tunnel and retry on a 4-second timeout, which shows up as
        // "connected but nothing loads".
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
          '0': {'statsUserUplink': true, 'statsUserDownlink': true},
        },
        'system': {
          'statsOutboundUplink': true,
          'statsOutboundDownlink': true,
        },
      };
    }

    return config;
  }

  String buildJson(ServerConfig server) =>
      const JsonEncoder.withIndent('  ').convert(build(server));
}
