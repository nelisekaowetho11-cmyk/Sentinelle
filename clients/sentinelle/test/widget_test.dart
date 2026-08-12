import 'package:flutter_test/flutter_test.dart';
import 'package:veil_client/models/models.dart';
import 'package:veil_client/services/api.dart';
import 'package:veil_client/services/xray_config.dart';

void main() {
  group('PanelApi.normalizeBaseUrl', () {
    test('picks https for bare domains, http for IPs and host:port', () {
      expect(PanelApi.normalizeBaseUrl('panel.example.com'),
          'https://panel.example.com');
      expect(PanelApi.normalizeBaseUrl('1.2.3.4:5000'), 'http://1.2.3.4:5000');
      expect(PanelApi.normalizeBaseUrl('1.2.3.4'), 'http://1.2.3.4');
      expect(PanelApi.normalizeBaseUrl('localhost:5000'), 'http://localhost:5000');
      expect(PanelApi.normalizeBaseUrl('panel.example.com:8443'),
          'http://panel.example.com:8443');
    });

    test('keeps an explicit scheme and trims trailing slashes', () {
      expect(PanelApi.normalizeBaseUrl('https://panel.example.com/'),
          'https://panel.example.com');
      expect(PanelApi.normalizeBaseUrl('  https://a.b//  '), 'https://a.b');
    });
  });

  group('countryFlag', () {
    test('maps ISO codes to flag emoji', () {
      expect(countryFlag('DE'), '🇩🇪');
      expect(countryFlag('de'), '🇩🇪');
    });

    test('returns empty for junk input', () {
      expect(countryFlag(''), '');
      expect(countryFlag('XYZ'), '');
    });
  });

  group('XrayConfigBuilder', () {
    ServerConfig sample() => ServerConfig.fromJson({
          'id': 1,
          'tag': 'reality-in',
          'name': 'Frankfurt',
          'protocol': 'vless',
          'transport': 'reality',
          'network': 'tcp',
          'security': 'reality',
          'address': '1.2.3.4',
          'port': 443,
          'link': 'vless://…',
          'outbound': {
            'tag': 'proxy',
            'protocol': 'vless',
            'settings': {
              'vnext': [
                {
                  'address': '1.2.3.4',
                  'port': 443,
                  'users': [
                    {'id': 'uuid-here', 'encryption': 'none', 'flow': 'xtls-rprx-vision'}
                  ]
                }
              ]
            },
            'streamSettings': {'network': 'tcp', 'security': 'reality'},
          },
        });

    test('proxy outbound comes first — the Android engine reads outbounds[0]', () {
      final cfg = const XrayConfigBuilder(
        socksPort: 10808,
        httpPort: 10809,
        dnsServers: ['1.1.1.1'],
        bypassLan: true,
        blockAds: false,
      ).build(sample());

      final outbounds = cfg['outbounds'] as List;
      expect(outbounds.first['tag'], 'proxy');
      expect(outbounds.first['settings']['vnext'][0]['address'], '1.2.3.4');
      expect(outbounds.map((o) => o['tag']), containsAll(['proxy', 'direct', 'block']));
    });

    test('exposes a socks inbound on the configured port', () {
      final cfg = const XrayConfigBuilder(
        socksPort: 11080,
        httpPort: 11081,
        dnsServers: [],
        bypassLan: false,
        blockAds: false,
      ).build(sample());

      final inbounds = (cfg['inbounds'] as List).cast<Map<String, dynamic>>();
      final socks = inbounds.firstWhere((i) => i['protocol'] == 'socks');
      expect(socks['port'], 11080);
      final http = inbounds.firstWhere((i) => i['protocol'] == 'http');
      expect(http['port'], 11081);
      // No api port requested -> no stats block.
      expect(cfg.containsKey('stats'), isFalse);
    });

    test('routes AsIs with explicit private CIDRs, not geo files', () {
      final cfg = const XrayConfigBuilder(
        socksPort: 10808,
        httpPort: 10809,
        dnsServers: ['1.1.1.1', '8.8.8.8'],
        bypassLan: true,
        blockAds: true,
      ).build(sample());

      // IPIfNonMatch made Xray pre-resolve every hostname over the tunnel,
      // which stalled Android on a 4s DNS timeout.
      expect(cfg['routing']['domainStrategy'], 'AsIs');

      final rules = (cfg['routing']['rules'] as List).cast<Map<String, dynamic>>();
      final lan = rules.firstWhere((r) => r['outboundTag'] == 'direct');
      expect(lan['ip'], contains('192.168.0.0/16'));
      expect(lan['ip'], isNot(contains('geoip:private')));
      final ads = rules.firstWhere((r) => r['outboundTag'] == 'block');
      expect((ads['domain'] as List).every((d) => !'$d'.startsWith('geosite:')),
          isTrue);

      // The plugin feeds these straight to VpnService.Builder.addDnsServer,
      // so they have to stay plain strings.
      expect(cfg['dns']['servers'], ['1.1.1.1', '8.8.8.8']);
      expect((cfg['dns']['servers'] as List).every((e) => e is String), isTrue);
    });

    test('adds the stats API plumbing when an api port is given', () {
      final cfg = const XrayConfigBuilder(
        socksPort: 10808,
        httpPort: 10809,
        dnsServers: [],
        bypassLan: true,
        blockAds: true,
        apiPort: 10810,
      ).build(sample());

      expect(cfg['api']['tag'], 'api');
      expect(cfg['stats'], isNotNull);
      final rules = (cfg['routing']['rules'] as List).cast<Map<String, dynamic>>();
      expect(rules.any((r) => r['outboundTag'] == 'api'), isTrue);
      expect(rules.any((r) => r['outboundTag'] == 'block'), isTrue);
      expect(rules.any((r) => r['outboundTag'] == 'direct'), isTrue);
    });
  });

  group('Profile', () {
    test('parses the panel payload', () {
      final p = Profile.fromJson({
        'id': 7,
        'name': 'Alex',
        'username': 'pvb10007',
        'status': 'active',
        'can_connect': true,
        'unlimited': false,
        'traffic_limit_gb': 50,
        'traffic_used_gb': 12.5,
        'traffic_left_gb': 37.5,
        'traffic_pct': 25.0,
        'expires': '2027-01-01',
        'days_left': 120,
      });
      expect(p.username, 'pvb10007');
      expect(p.trafficLeftGb, 37.5);
      expect(p.canConnect, isTrue);
    });
  });
}
