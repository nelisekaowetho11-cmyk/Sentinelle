import 'package:flutter_test/flutter_test.dart';
import 'package:veil_client/models/models.dart';
import 'package:veil_client/services/singbox_config.dart';

ServerConfig sample({
  String protocol = 'vless',
  String security = 'reality',
  String network = 'tcp',
  Map<String, dynamic>? settings,
  Map<String, dynamic>? stream,
}) =>
    ServerConfig.fromJson({
      'id': 1,
      'tag': 'in-1',
      'name': 'Frankfurt',
      'country': 'DE',
      'protocol': protocol,
      'transport': security == 'reality' ? 'reality' : network,
      'network': network,
      'security': security,
      'address': '1.2.3.4',
      'port': 443,
      'link': '',
      'outbound': {
        'tag': 'proxy',
        'protocol': protocol,
        'settings': settings ??
            {
              'vnext': [
                {
                  'address': '1.2.3.4',
                  'port': 443,
                  'users': [
                    {
                      'id': 'uuid-1',
                      'encryption': 'none',
                      'flow': 'xtls-rprx-vision',
                    }
                  ],
                }
              ],
            },
        'streamSettings': stream ??
            {
              'network': network,
              'security': security,
              'realitySettings': {
                'serverName': 'www.cloudflare.com',
                'fingerprint': 'chrome',
                'publicKey': 'PUBKEY',
                'shortId': 'abcd1234',
              },
            },
      },
    });

const proxyBuilder = SingBoxConfigBuilder(
  mode: TunnelMode.proxy,
  socksPort: 10808,
  httpPort: 10809,
  dnsServers: ['1.1.1.1', '8.8.8.8'],
  bypassLan: true,
  blockAds: false,
);

const vpnBuilder = SingBoxConfigBuilder(
  mode: TunnelMode.vpn,
  socksPort: 10808,
  httpPort: 10809,
  dnsServers: ['1.1.1.1', '8.8.8.8'],
  bypassLan: true,
  blockAds: true,
  clashApiPort: 19090,
);

void main() {
  _multiTunnelTests();
  group('inbounds', () {
    test('proxy mode exposes local listeners and no tun', () {
      final cfg = proxyBuilder.build(sample());
      final inbounds = (cfg['inbounds'] as List).cast<Map<String, dynamic>>();
      expect(inbounds.any((i) => i['type'] == 'tun'), isFalse);
      expect(inbounds.firstWhere((i) => i['tag'] == 'mixed-in')['listen_port'],
          10808);
      expect(inbounds.firstWhere((i) => i['tag'] == 'http-in')['listen_port'],
          10809);
    });

    test('vpn mode adds a tun device with auto_route', () {
      final cfg = vpnBuilder.build(sample());
      final inbounds = (cfg['inbounds'] as List).cast<Map<String, dynamic>>();
      final tun = inbounds.firstWhere((i) => i['type'] == 'tun');
      expect(tun['auto_route'], isTrue);
      expect(tun['strict_route'], isTrue);
      // The local listener stays so the app can still probe liveness.
      expect(inbounds.any((i) => i['tag'] == 'mixed-in'), isTrue);
    });

    test('a shared socks/http port does not produce a duplicate inbound', () {
      const b = SingBoxConfigBuilder(
        mode: TunnelMode.proxy,
        socksPort: 10808,
        httpPort: 10808,
        dnsServers: [],
        bypassLan: false,
        blockAds: false,
      );
      final inbounds = (b.build(sample())['inbounds'] as List);
      expect(inbounds.length, 1);
    });
  });

  group('routing and dns', () {
    test('uses the 1.12+ schema, not the removed legacy forms', () {
      final cfg = vpnBuilder.build(sample());

      // New-style DNS servers carry an explicit type.
      final servers = (cfg['dns']['servers'] as List).cast<Map<String, dynamic>>();
      expect(servers.every((s) => s.containsKey('type')), isTrue);
      expect(servers.first['server'], '1.1.1.1');

      // domain_resolver replaced outbound DNS rule items.
      expect(cfg['route']['default_domain_resolver'], isNotNull);

      // Rule actions replaced the removed block/dns outbound types.
      final rules = (cfg['route']['rules'] as List).cast<Map<String, dynamic>>();
      expect(rules.any((r) => r['action'] == 'sniff'), isTrue);
      expect(rules.any((r) => r['action'] == 'hijack-dns'), isTrue);
      final outbounds = (cfg['outbounds'] as List).cast<Map<String, dynamic>>();
      expect(outbounds.any((o) => o['type'] == 'block'), isFalse);
      expect(outbounds.any((o) => o['type'] == 'dns'), isFalse);
    });

    test('bypassLan adds a private-IP direct rule', () {
      final rules = (proxyBuilder.build(sample())['route']['rules'] as List)
          .cast<Map<String, dynamic>>();
      expect(
          rules.any((r) => r['ip_is_private'] == true && r['outbound'] == 'direct'),
          isTrue);
    });

    test('clash api is only declared when a port is given', () {
      expect(proxyBuilder.build(sample())['experimental'], isNull);
      expect(
        vpnBuilder.build(sample())['experimental']['clash_api']
            ['external_controller'],
        '127.0.0.1:19090',
      );
    });
  });

  group('outbound translation', () {
    test('vless + reality keeps flow, utls and the reality keys', () {
      final ob = (proxyBuilder.build(sample())['outbounds'] as List).first
          as Map<String, dynamic>;
      expect(ob['type'], 'vless');
      expect(ob['uuid'], 'uuid-1');
      expect(ob['flow'], 'xtls-rprx-vision');
      expect(ob['tls']['reality']['enabled'], isTrue);
      expect(ob['tls']['reality']['public_key'], 'PUBKEY');
      expect(ob['tls']['reality']['short_id'], 'abcd1234');
      expect(ob['tls']['server_name'], 'www.cloudflare.com');
      expect(ob['tls']['utls']['fingerprint'], 'chrome');
    });

    test('vless over ws carries the path and Host header', () {
      final s = sample(security: 'tls', network: 'ws', settings: {
        'vnext': [
          {
            'address': '1.2.3.4',
            'port': 443,
            'users': [
              {'id': 'uuid-1', 'encryption': 'none'}
            ],
          }
        ],
      }, stream: {
        'network': 'ws',
        'security': 'tls',
        'tlsSettings': {'serverName': 'edge.example.com', 'fingerprint': 'chrome'},
        'wsSettings': {'path': '/ws', 'host': 'edge.example.com'},
      });
      final ob = (proxyBuilder.build(s)['outbounds'] as List).first
          as Map<String, dynamic>;
      expect(ob['transport']['type'], 'ws');
      expect(ob['transport']['path'], '/ws');
      expect(ob['transport']['headers']['Host'], 'edge.example.com');
      expect(ob['tls']['server_name'], 'edge.example.com');
      expect(ob['flow'], isNull, reason: 'no vision flow outside reality');
    });

    test('trojan and shadowsocks read from the servers list', () {
      final trojan = sample(
        protocol: 'trojan',
        security: 'tls',
        settings: {
          'servers': [
            {'address': '1.2.3.4', 'port': 443, 'password': 'pw-1'}
          ]
        },
        stream: {
          'network': 'tcp',
          'security': 'tls',
          'tlsSettings': {'serverName': 'a.example.com'},
        },
      );
      final tOb = (proxyBuilder.build(trojan)['outbounds'] as List).first
          as Map<String, dynamic>;
      expect(tOb['type'], 'trojan');
      expect(tOb['password'], 'pw-1');

      final ss = sample(
        protocol: 'shadowsocks',
        security: 'none',
        settings: {
          'servers': [
            {
              'address': '1.2.3.4',
              'port': 8388,
              'method': 'aes-256-gcm',
              'password': 'ss-pw',
            }
          ]
        },
        stream: {'network': 'tcp', 'security': 'none'},
      );
      final sOb = (proxyBuilder.build(ss)['outbounds'] as List).first
          as Map<String, dynamic>;
      expect(sOb['type'], 'shadowsocks');
      expect(sOb['method'], 'aes-256-gcm');
      expect(sOb['password'], 'ss-pw');
      expect(sOb['tls'], isNull);
    });

    test('vmess maps security and alterId', () {
      final s = sample(
        protocol: 'vmess',
        security: 'none',
        settings: {
          'vnext': [
            {
              'address': '1.2.3.4',
              'port': 443,
              'users': [
                {'id': 'uuid-2', 'alterId': 0, 'security': 'auto'}
              ],
            }
          ],
        },
        stream: {'network': 'tcp', 'security': 'none'},
      );
      final ob =
          (proxyBuilder.build(s)['outbounds'] as List).first as Map<String, dynamic>;
      expect(ob['type'], 'vmess');
      expect(ob['uuid'], 'uuid-2');
      expect(ob['alter_id'], 0);
      expect(ob['security'], 'auto');
    });
  });

  group('supports()', () {
    test('accepts what sing-box can carry', () {
      expect(SingBoxConfigBuilder.supports(sample()), isTrue);
      expect(
          SingBoxConfigBuilder.supports(sample(network: 'ws', security: 'tls')),
          isTrue);
      expect(SingBoxConfigBuilder.supports(sample(protocol: 'trojan')), isTrue);
    });

    test('rejects transports with no sing-box equivalent', () {
      expect(SingBoxConfigBuilder.supports(sample(network: 'xhttp')), isFalse);
      expect(SingBoxConfigBuilder.supports(sample(network: 'kcp')), isFalse);
    });

    test('an unsupported transport throws rather than emitting junk', () {
      expect(
        () => proxyBuilder.build(sample(
          network: 'xhttp',
          stream: {'network': 'xhttp', 'security': 'none'},
        )),
        throwsUnsupportedError,
      );
    });
  });
}

void _multiTunnelTests() {
  group('per-app tunnels', () {
    ServerConfig other() => ServerConfig.fromJson({
          'id': 2,
          'tag': 'in-2',
          'name': 'Amsterdam',
          'country': 'NL',
          'protocol': 'trojan',
          'network': 'tcp',
          'security': 'tls',
          'address': '5.6.7.8',
          'port': 8443,
          'outbound': {
            'protocol': 'trojan',
            'settings': {
              'servers': [
                {'address': '5.6.7.8', 'port': 8443, 'password': 'hunter2'}
              ]
            },
            'streamSettings': {'network': 'tcp', 'security': 'tls'},
          },
        });

    test('each bound app gets its own outbound and process rule', () {
      final config = SingBoxConfigBuilder(
        mode: TunnelMode.vpn,
        socksPort: 10808,
        httpPort: 10809,
        dnsServers: const ['1.1.1.1'],
        bypassLan: true,
        blockAds: false,
        appRoutes: [
          AppRoute(processes: const ['chrome.exe'], server: other()),
        ],
      ).build(sample());

      final outbounds = (config['outbounds'] as List)
          .cast<Map<String, dynamic>>();
      final tags = outbounds.map((o) => o['tag']).toList();

      // The main tunnel and the app's tunnel are live at the same time.
      expect(tags, contains('proxy'));
      expect(tags, contains('proxy-app-0'));

      final appOut = outbounds.firstWhere((o) => o['tag'] == 'proxy-app-0');
      expect(appOut['type'], 'trojan');
      expect(appOut['server'], '5.6.7.8');
      expect(appOut['server_port'], 8443);

      final rules =
          ((config['route'] as Map)['rules'] as List).cast<Map<String, dynamic>>();
      final appRule =
          rules.firstWhere((r) => r['outbound'] == 'proxy-app-0');
      expect(appRule['process_name'], ['chrome.exe']);
    });

    test('apps sharing a location share one outbound', () {
      final server = other();
      final config = SingBoxConfigBuilder(
        mode: TunnelMode.vpn,
        socksPort: 10808,
        httpPort: 10809,
        dnsServers: const ['1.1.1.1'],
        bypassLan: true,
        blockAds: false,
        appRoutes: [
          AppRoute(processes: const ['chrome.exe', 'brave.exe'], server: server),
        ],
      ).build(sample());

      final outbounds =
          (config['outbounds'] as List).cast<Map<String, dynamic>>();
      expect(outbounds.where((o) => '${o['tag']}'.startsWith('proxy-app-')),
          hasLength(1));

      final rules =
          ((config['route'] as Map)['rules'] as List).cast<Map<String, dynamic>>();
      expect(rules.firstWhere((r) => r['outbound'] == 'proxy-app-0')['process_name'],
          ['chrome.exe', 'brave.exe']);
    });

    test('no bindings leaves the config exactly as it was', () {
      final config = vpnBuilder.build(sample());
      final tags =
          (config['outbounds'] as List).map((o) => (o as Map)['tag']).toList();
      expect(tags.where((t) => '$t'.startsWith('proxy-app-')), isEmpty);
    });
  });

  group('leak guards', () {
    test('LAN discovery and QUIC are rejected when their guards are on', () {
      final config = SingBoxConfigBuilder(
        mode: TunnelMode.vpn,
        socksPort: 10808,
        httpPort: 10809,
        dnsServers: const ['1.1.1.1'],
        bypassLan: true,
        blockAds: false,
        lanGuard: true,
        quicGuard: true,
      ).build(sample());

      final rules =
          ((config['route'] as Map)['rules'] as List).cast<Map<String, dynamic>>();
      final rejects = rules.where((r) => r['action'] == 'reject').toList();

      expect(
        rejects.any((r) => _portsOf(r).contains(5353)),
        isTrue,
        reason: 'mDNS announces the device by name to the local network',
      );
      expect(
        rejects.any((r) => r['network'] == 'udp' && r['port'] == 443),
        isTrue,
        reason: 'QUIC must be refused so browsers fall back to TCP',
      );
    });

    test('guards left off add no rules', () {
      final config = SingBoxConfigBuilder(
        mode: TunnelMode.vpn,
        socksPort: 10808,
        httpPort: 10809,
        dnsServers: const ['1.1.1.1'],
        bypassLan: true,
        blockAds: false,
        lanGuard: false,
        quicGuard: false,
      ).build(sample());

      final rules =
          ((config['route'] as Map)['rules'] as List).cast<Map<String, dynamic>>();
      expect(rules.any((r) => _portsOf(r).contains(5353)), isFalse);
      expect(rules.any((r) => r['network'] == 'udp' && r['port'] == 443),
          isFalse);
    });
  });
}

/// `port` is an int on some rules and a list on others, so a plain cast is not
/// safe here.
List<int> _portsOf(Map<String, dynamic> rule) {
  final p = rule['port'];
  if (p is int) return [p];
  if (p is List) return p.whereType<int>().toList();
  return const [];
}
