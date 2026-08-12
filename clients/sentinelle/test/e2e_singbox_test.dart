@Tags(['e2e'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:veil_client/services/api.dart';
import 'package:veil_client/services/routing.dart';
import 'package:veil_client/services/singbox_config.dart';

/// End-to-end check of the desktop tunnel: log into a live panel, translate the
/// outbound it returns into a sing-box config, run the real core, and push
/// traffic through the proxy it exposes.
///
/// Opt-in — needs a running panel and a sing-box binary:
///   flutter test test/e2e_singbox_test.dart --tags e2e \
///     --dart-define=PANEL=http://127.0.0.1:5055 \
///     --dart-define=USER=pvb10001 --dart-define=PASS=xxxxxxxx \
///     --dart-define=SINGBOX=C:\path\to\sing-box.exe
void main() {
  const panel = String.fromEnvironment('PANEL');
  const user = String.fromEnvironment('USER');
  const pass = String.fromEnvironment('PASS');
  const singbox = String.fromEnvironment('SINGBOX');

  test('panel config drives a working sing-box tunnel', () async {
    if (panel.isEmpty || user.isEmpty || pass.isEmpty || singbox.isEmpty) {
      markTestSkipped('PANEL/USER/PASS/SINGBOX dart-defines not provided');
      return;
    }

    // 1. Sign in the way the app does.
    final api = PanelApi(baseUrl: await PanelApi.resolveBaseUrl(panel));
    final res = await api.login(user, pass);
    expect(res.session.servers, isNotEmpty);
    final server = res.session.servers.first;
    // ignore: avoid_print
    print('server: ${server.name} ${server.protoLabel} '
        '${server.address}:${server.port}');
    expect(SingBoxConfigBuilder.supports(server), isTrue);

    // 2. Build the config with the production builder — proxy mode, since TUN
    //    needs administrator rights that CI/test runs will not have.
    const socksPort = 21180;
    const httpPort = 21181;
    const clashPort = 21182;
    final json = const SingBoxConfigBuilder(
      mode: TunnelMode.proxy,
      socksPort: socksPort,
      httpPort: httpPort,
      dnsServers: ['1.1.1.1', '8.8.8.8'],
      bypassLan: true,
      blockAds: false,
      clashApiPort: clashPort,
    ).buildJson(server);

    final dir = await Directory.systemTemp.createTemp('veil-sb-e2e');
    final cfg = File('${dir.path}/config.json');
    await cfg.writeAsString(json);

    // 3. The core must accept it before we even try to run it.
    final check = await Process.run(singbox, ['check', '-c', cfg.path]);
    expect(check.exitCode, 0,
        reason: 'sing-box rejected the generated config:\n'
            '${check.stderr}\n$json');

    // 3b. VPN (TUN) mode cannot be *run* without administrator rights, but the
    //     config it produces still has to be one the core accepts.
    final vpnCfg = File('${dir.path}/config-vpn.json');
    await vpnCfg.writeAsString(const SingBoxConfigBuilder(
      mode: TunnelMode.vpn,
      socksPort: socksPort,
      httpPort: httpPort,
      dnsServers: ['1.1.1.1', '8.8.8.8'],
      bypassLan: true,
      blockAds: true,
      clashApiPort: clashPort,
    ).buildJson(server));
    final vpnCheck = await Process.run(singbox, ['check', '-c', vpnCfg.path]);
    expect(vpnCheck.exitCode, 0,
        reason: 'sing-box rejected the VPN-mode config:\n${vpnCheck.stderr}');

    // 3c. Split tunnelling and custom domain/IP rules must be accepted too —
    //     process_name, domain_suffix and ip_cidr are all schema-checked.
    for (final mode in SplitMode.values) {
      final splitCfg = File('${dir.path}/config-split-${mode.name}.json');
      await splitCfg.writeAsString(SingBoxConfigBuilder(
        mode: TunnelMode.vpn,
        socksPort: socksPort,
        httpPort: httpPort,
        dnsServers: const ['1.1.1.1', '8.8.8.8'],
        bypassLan: true,
        blockAds: true,
        splitMode: mode,
        splitApps: const ['chrome.exe', 'steam.exe'],
        forceTunnel: RoutingRules.parse(const ['netflix.com', '203.0.113.0/24']),
        forceDirect:
            RoutingRules.parse(const ['bank.example.com', '10.20.0.0/16']),
      ).buildJson(server));
      final splitCheck =
          await Process.run(singbox, ['check', '-c', splitCfg.path]);
      expect(splitCheck.exitCode, 0,
          reason: 'sing-box rejected the ${mode.name} split config:\n'
              '${splitCheck.stderr}');
    }

    // 4. Run it.
    final proc = await Process.start(
      singbox,
      ['run', '-c', cfg.path, '-D', File(singbox).parent.path],
      workingDirectory: File(singbox).parent.path,
    );
    final logLines = <String>[];
    proc.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen(logLines.add);
    proc.stderr.transform(utf8.decoder).transform(const LineSplitter()).listen(logLines.add);

    try {
      var listening = false;
      for (var i = 0; i < 40 && !listening; i++) {
        try {
          final s = await Socket.connect('127.0.0.1', socksPort,
              timeout: const Duration(milliseconds: 300));
          s.destroy();
          listening = true;
        } catch (_) {
          await Future<void>.delayed(const Duration(milliseconds: 250));
        }
      }
      expect(listening, isTrue,
          reason: 'core never listened on $socksPort:\n${logLines.join('\n')}');

      // 5. Real traffic through the tunnel.
      final client = HttpClient();
      client.findProxy = (_) => 'PROXY 127.0.0.1:$httpPort';
      client.connectionTimeout = const Duration(seconds: 15);
      final req = await client
          .getUrl(Uri.parse('http://cp.cloudflare.com/generate_204'));
      final resp = await req.close().timeout(const Duration(seconds: 25));
      await resp.drain<void>();
      client.close(force: true);

      // ignore: avoid_print
      print('proxied request status: ${resp.statusCode}');
      expect(resp.statusCode, anyOf(200, 204),
          reason: 'traffic did not survive the tunnel:\n${logLines.join('\n')}');

      // 6. The Clash API the Stats screen polls must answer.
      final stats = HttpClient();
      final sReq = await stats
          .getUrl(Uri.parse('http://127.0.0.1:$clashPort/connections'));
      final sResp = await sReq.close().timeout(const Duration(seconds: 10));
      final body = await sResp.transform(utf8.decoder).join();
      stats.close(force: true);
      expect(sResp.statusCode, 200);
      final counters = jsonDecode(body) as Map<String, dynamic>;
      // ignore: avoid_print
      print('clash counters: up=${counters['uploadTotal']} '
          'down=${counters['downloadTotal']}');
      expect(counters.containsKey('downloadTotal'), isTrue);
      expect((counters['downloadTotal'] as num).toInt(), greaterThan(0),
          reason: 'traffic counters should have moved');
    } finally {
      proc.kill(ProcessSignal.sigterm);
      api.close();
      await dir.delete(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 2)));
}
