import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter_test/flutter_test.dart';
import 'package:veil_client/models/models.dart';
import 'package:veil_client/services/routing.dart';
import 'package:veil_client/services/singbox_config.dart';
import 'package:veil_client/services/xray_config.dart';

ServerConfig sample() => ServerConfig.fromJson({
      'id': 1,
      'tag': 'in-1',
      'name': 'Frankfurt',
      'protocol': 'vless',
      'transport': 'reality',
      'network': 'tcp',
      'security': 'reality',
      'address': '1.2.3.4',
      'port': 443,
      'link': '',
      'outbound': {
        'tag': 'proxy',
        'protocol': 'vless',
        'settings': {
          'vnext': [
            {
              'address': '1.2.3.4',
              'port': 443,
              'users': [
                {'id': 'uuid-1', 'encryption': 'none', 'flow': 'xtls-rprx-vision'}
              ],
            }
          ],
        },
        'streamSettings': {
          'network': 'tcp',
          'security': 'reality',
          'realitySettings': {
            'serverName': 'www.cloudflare.com',
            'fingerprint': 'chrome',
            'publicKey': 'PUB',
            'shortId': 'abcd1234',
          },
        },
      },
    });

void main() {
  group('RoutingRules.parse', () {
    test('separates domains from IPs and CIDRs', () {
      final r = RoutingRules.parse([
        'netflix.com',
        'https://Bank.Example.com/login',
        '8.8.8.8',
        '10.0.0.0/8',
        '2001:db8::1',
        '   ',
      ]);
      expect(r.domains, ['netflix.com', 'bank.example.com']);
      expect(r.ips, ['8.8.8.8/32', '10.0.0.0/8', '2001:db8::1/128']);
    });

    test('bare addresses get a single-host prefix — both cores require one', () {
      expect(RoutingRules.parse(['1.1.1.1']).ips, ['1.1.1.1/32']);
      expect(RoutingRules.parse(['1.1.1.1/24']).ips, ['1.1.1.1/24']);
    });

    test('splitInput accepts commas, spaces and newlines', () {
      expect(RoutingRules.splitInput('a.com, b.com\n c.com\t d.com'),
          ['a.com', 'b.com', 'c.com', 'd.com']);
    });
  });

  group('sing-box split tunnelling', () {
    SingBoxConfigBuilder builder({
      SplitMode mode = SplitMode.all,
      List<String> apps = const [],
      RoutingRules? tunnel,
      RoutingRules? direct,
    }) =>
        SingBoxConfigBuilder(
          mode: TunnelMode.vpn,
          socksPort: 10808,
          httpPort: 10809,
          dnsServers: const ['1.1.1.1'],
          bypassLan: true,
          blockAds: false,
          splitMode: mode,
          splitApps: apps,
          forceTunnel: tunnel ?? const RoutingRules(domains: [], ips: []),
          forceDirect: direct ?? const RoutingRules(domains: [], ips: []),
        );

    List<Map<String, dynamic>> rulesOf(Map<String, dynamic> cfg) =>
        (cfg['route']['rules'] as List).cast<Map<String, dynamic>>();

    test('all-apps mode adds no process rule and keeps proxy as the fallback', () {
      final cfg = builder().build(sample());
      expect(rulesOf(cfg).any((r) => r.containsKey('process_name')), isFalse);
      expect(cfg['route']['final'], 'proxy');
    });

    test('"all except" sends the listed apps direct', () {
      final cfg = builder(
        mode: SplitMode.exceptListed,
        apps: ['chrome.exe', 'steam.exe'],
      ).build(sample());
      final rule =
          rulesOf(cfg).firstWhere((r) => r.containsKey('process_name'));
      expect(rule['process_name'], ['chrome.exe', 'steam.exe']);
      expect(rule['outbound'], 'direct');
      expect(cfg['route']['final'], 'proxy');
    });

    test('"only these" flips the fallback so everything else is direct', () {
      final cfg = builder(
        mode: SplitMode.onlyListed,
        apps: ['chrome.exe'],
      ).build(sample());
      final rule =
          rulesOf(cfg).firstWhere((r) => r.containsKey('process_name'));
      expect(rule['outbound'], 'proxy');
      expect(cfg['route']['final'], 'direct',
          reason: 'otherwise unlisted apps would still be tunnelled');
    });

    test('an empty app list never flips the fallback', () {
      final cfg = builder(mode: SplitMode.onlyListed).build(sample());
      expect(cfg['route']['final'], 'proxy');
    });

    test('domain and IP rules land in the right fields, direct before proxy', () {
      final cfg = builder(
        tunnel: RoutingRules.parse(['netflix.com', '203.0.113.0/24']),
        direct: RoutingRules.parse(['bank.example.com', '10.20.0.0/16']),
      ).build(sample());

      final rules = rulesOf(cfg);
      bool has(Map<String, dynamic> r, String key, List<String> value) =>
          listEquals((r[key] as List?)?.cast<String>(), value);

      final directDomain = rules
          .indexWhere((r) => has(r, 'domain_suffix', ['bank.example.com']));
      final proxyDomain =
          rules.indexWhere((r) => has(r, 'domain_suffix', ['netflix.com']));
      expect(directDomain, isNonNegative);
      expect(proxyDomain, isNonNegative);
      expect(directDomain, lessThan(proxyDomain),
          reason: '"never tunnel" must win over "always tunnel"');

      expect(
          rules.any((r) =>
              has(r, 'ip_cidr', ['10.20.0.0/16']) && r['outbound'] == 'direct'),
          isTrue);
      expect(
          rules.any((r) =>
              has(r, 'ip_cidr', ['203.0.113.0/24']) && r['outbound'] == 'proxy'),
          isTrue);
    });
  });

  group('xray routing rules (Android)', () {
    test('domains are emitted with the domain: prefix and IPs as CIDRs', () {
      final cfg = XrayConfigBuilder(
        socksPort: 10808,
        httpPort: 10809,
        dnsServers: const ['1.1.1.1'],
        bypassLan: true,
        blockAds: false,
        forceTunnel: RoutingRules.parse(['netflix.com']),
        forceDirect: RoutingRules.parse(['bank.example.com', '10.20.0.0/16']),
      ).build(sample());

      final rules = (cfg['routing']['rules'] as List).cast<Map<String, dynamic>>();
      bool has(Map<String, dynamic> r, String key, List<String> value) =>
          listEquals((r[key] as List?)?.cast<String>(), value);

      expect(
          rules.any((r) =>
              has(r, 'domain', ['domain:bank.example.com']) &&
              r['outboundTag'] == 'direct'),
          isTrue);
      expect(
          rules.any((r) =>
              has(r, 'domain', ['domain:netflix.com']) &&
              r['outboundTag'] == 'proxy'),
          isTrue);
      expect(
          rules.any((r) =>
              has(r, 'ip', ['10.20.0.0/16']) && r['outboundTag'] == 'direct'),
          isTrue);
    });
  });

  group('SplitMode labels', () {
    test('every mode has a label and description', () {
      for (final m in SplitMode.values) {
        expect(m.label, isNotEmpty);
        expect(m.description, isNotEmpty);
      }
    });
  });
}
