@Tags(['e2e'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:veil_client/services/api.dart';
import 'package:veil_client/services/xray_config.dart';

/// End-to-end check: log into a live panel, take the outbound it hands back,
/// build the client config exactly the way the app does, run a real Xray core
/// with it and push traffic through the resulting SOCKS proxy.
///
/// Opt-in — it needs a running panel plus an Xray binary:
///   flutter test test/e2e_tunnel_test.dart --tags e2e \
///     --dart-define=PANEL=http://127.0.0.1:5055 \
///     --dart-define=USER=pvb10001 --dart-define=PASS=xxxxxxxx \
///     --dart-define=XRAY=C:\path\to\xray.exe
void main() {
  const panel = String.fromEnvironment('PANEL');
  const user = String.fromEnvironment('USER');
  const pass = String.fromEnvironment('PASS');
  const xray = String.fromEnvironment('XRAY');

  test('panel config drives a working tunnel', () async {
    if (panel.isEmpty || user.isEmpty || pass.isEmpty || xray.isEmpty) {
      markTestSkipped('PANEL/USER/PASS/XRAY dart-defines not provided');
      return;
    }

    // 1. Sign in exactly like the app does.
    final api = PanelApi(baseUrl: await PanelApi.resolveBaseUrl(panel));
    final res = await api.login(user, pass);
    expect(res.session.profile.canConnect, isTrue,
        reason: 'test account must be active');
    expect(res.session.servers, isNotEmpty,
        reason: 'test account needs at least one inbound');

    final server = res.session.servers.first;
    // ignore: avoid_print
    print('server: ${server.name} ${server.protoLabel} '
        '${server.address}:${server.port}');

    // 2. Build the client config with the production builder.
    const socksPort = 21080;
    const httpPort = 21081;
    const apiPort = 21082;
    final json = const XrayConfigBuilder(
      socksPort: socksPort,
      httpPort: httpPort,
      dnsServers: ['1.1.1.1', '8.8.8.8'],
      bypassLan: true,
      blockAds: false,
      apiPort: apiPort,
    ).buildJson(server);

    final dir = await Directory.systemTemp.createTemp('veil-e2e');
    final cfg = File('${dir.path}/config.json');
    await cfg.writeAsString(json);

    // 3. Run the core.
    final proc = await Process.start(
      xray,
      ['run', '-c', cfg.path],
      workingDirectory: File(xray).parent.path,
      environment: {'XRAY_LOCATION_ASSET': File(xray).parent.path},
    );
    final logLines = <String>[];
    proc.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen(logLines.add);
    proc.stderr.transform(utf8.decoder).transform(const LineSplitter()).listen(logLines.add);

    try {
      // 4. Wait for the SOCKS listener — proves the config was accepted.
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

      // 5. Push a real request through the tunnel.
      final client = HttpClient();
      client.findProxy = (_) => 'PROXY 127.0.0.1:$httpPort';
      client.connectionTimeout = const Duration(seconds: 15);
      final req = await client
          .getUrl(Uri.parse('http://cp.cloudflare.com/generate_204'));
      final resp = await req.close().timeout(const Duration(seconds: 20));
      await resp.drain<void>();
      client.close(force: true);

      // ignore: avoid_print
      print('proxied request status: ${resp.statusCode}');
      expect(resp.statusCode, anyOf(200, 204),
          reason: 'traffic did not survive the tunnel:\n${logLines.join('\n')}');

      // 6. The stats API must answer, since the Stats screen depends on it.
      final stats = await Process.run(xray, [
        'api',
        'statsquery',
        '--server=127.0.0.1:$apiPort',
        'outbound>>>proxy>>>traffic',
      ]);
      expect(stats.exitCode, 0, reason: stats.stderr.toString());
      final parsed = jsonDecode(stats.stdout as String) as Map<String, dynamic>;
      final names = ((parsed['stat'] as List?) ?? [])
          .map((e) => e['name'] as String)
          .toList();
      // ignore: avoid_print
      print('stats counters: $names');
      expect(names.any((n) => n.contains('proxy')), isTrue);
    } finally {
      proc.kill(ProcessSignal.sigterm);
      api.close();
      await dir.delete(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 2)));
}
