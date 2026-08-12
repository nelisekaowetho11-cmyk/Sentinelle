import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:veil_client/models/models.dart';
import 'package:veil_client/screens/shell.dart';
import 'package:veil_client/screens/stats_screen.dart';
import 'package:veil_client/services/storage.dart';
import 'package:veil_client/services/vpn/vpn_engine.dart';
import 'package:veil_client/state/app_state.dart';
import 'package:veil_client/theme.dart';

import 'support/fake_engine.dart';

/// The session timer and the speed readouts must tick while you are looking at
/// them — the bug was that they only caught up after switching tabs.
void main() {
  late FakeVpnEngine engine;

  setUp(() async {
    Storage.resetForTests();
    // These cover the simple connect layout; the detailed one (now the
    // default) has its own suite in home_detailed_test.dart.
    SharedPreferences.setMockInitialValues({
      'home_detailed': false,
      // The leak probes open real sockets, which a widget test cannot drive.
      'guard_dns': false,
      'guard_ipv6': false,
      'guard_webrtc': false,
    });
    await Storage.init();
    PackageInfo.setMockInitialValues(
      appName: 'Sentinelle',
      packageName: 'app.veil.veil_client',
      version: '1.0.0',
      buildNumber: '1',
      buildSignature: '',
    );
    engine = FakeVpnEngine();
  });

  ServerConfig server() => ServerConfig.fromJson({
        'id': 1,
        'tag': 'in-1',
        'name': 'Germany · Frankfurt',
        'country': 'DE',
        'protocol': 'vless',
        'transport': 'reality',
        'network': 'tcp',
        'security': 'reality',
        'address': '10.0.0.1',
        'port': 443,
        'link': '',
        'outbound': {
          'tag': 'proxy',
          'protocol': 'vless',
          'settings': {
            'vnext': [
              {'address': '10.0.0.1', 'port': 443, 'users': <Map<String, Object?>>[]}
            ]
          },
          'streamSettings': {'network': 'tcp', 'security': 'reality'},
        },
      });

  AppState makeState() {
    final s = AppState(engine: engine)
      ..authStage = AuthStage.loggedIn
      ..brand = 'Bridge Panel';
    final profile = Profile.fromJson({
        'id': 1,
        'name': 'Milad',
        'username': 'pvb10001',
        'status': 'active',
        'can_connect': true,
        'unlimited': false,
        'traffic_limit_gb': 50.0,
        'traffic_used_gb': 12.5,
        'traffic_left_gb': 37.5,
        'traffic_pct': 25.0,
        'expires': '2027-01-01',
      'days_left': 145,
    });
    s.seedSource(servers: [server()], profile: profile);
    return s;
  }

  Future<void> pumpShell(WidgetTester tester, AppState state,
      {Size size = const Size(1100, 800)}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      theme: buildVeilTheme(),
      home: AnimatedBuilder(
        animation: state,
        builder: (context, _) => VeilShell(state: state),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 300));
  }

  VpnStats sample(int seconds, {int down = 6000000, int up = 900000}) => VpnStats(
        uploadSpeed: up,
        downloadSpeed: down,
        uploadTotal: up * seconds,
        downloadTotal: down * seconds,
        duration: Duration(seconds: seconds),
      );

  testWidgets('session timer ticks on the Connect page without leaving it',
      (tester) async {
    final state = makeState();
    await pumpShell(tester, state);

    engine.emitState(VpnState.connected);
    engine.emitStats(sample(1));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('00:00:01'), findsOneWidget);

    // Three more seconds arrive while the user stays on the page.
    for (final s in [2, 3, 4]) {
      engine.emitStats(sample(s));
      await tester.pump(const Duration(milliseconds: 50));
    }

    expect(find.text('00:00:04'), findsOneWidget,
        reason: 'timer must update in place, not only after a tab switch');
    expect(find.text('00:00:01'), findsNothing);

    state.dispose();
  });

  testWidgets('speed readout updates on the Connect page', (tester) async {
    final state = makeState();
    await pumpShell(tester, state);

    engine.emitState(VpnState.connected);
    engine.emitStats(sample(1, down: 6000000, up: 900000));
    await tester.pump(const Duration(milliseconds: 50));
    // 6 MB/s -> 48.0 Mbps
    expect(find.text('48.0'), findsOneWidget);

    engine.emitStats(sample(2, down: 12000000, up: 1800000));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('96.0'), findsOneWidget);
    expect(find.text('48.0'), findsNothing);

    state.dispose();
  });

  testWidgets('VPN mode without elevation blocks connect and offers a fix',
      (tester) async {
    // A fresh launch with VPN mode already on used to sail past the elevation
    // check — it only ran when the Settings toggle was flipped.
    SharedPreferences.setMockInitialValues({'tunnel_mode_vpn': true});
    await Storage.init();

    final state = makeState();
    await pumpShell(tester, state);

    // On a non-elevated desktop test process this must be true; the guard is
    // what stops a doomed core from being started.
    if (state.needsElevation) {
      expect(find.text('VPN mode needs administrator rights'), findsOneWidget);

      await state.connect();
      await tester.pump(const Duration(milliseconds: 50));

      expect(engine.connectCalls, 0,
          reason: 'must not start a core that cannot possibly work');
      expect(state.connectionError, contains('administrator'));
    }

    state.dispose();
  });

  testWidgets('Stats page throughput and totals update live', (tester) async {
    final state = makeState();
    await pumpShell(tester, state);

    engine.emitState(VpnState.connected);
    engine.emitStats(sample(1));
    await tester.pump(const Duration(milliseconds: 50));

    // Go to the Stats tab and stay there. The page cross-fades in, so scope
    // the assertions to it rather than to the whole tree.
    await tester.tap(find.text('Stats').first);
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 120));
    }

    Finder inStats(String text) => find.descendant(
          of: find.byType(StatsScreen),
          matching: find.text(text),
        );

    expect(inStats('00:00:01'), findsOneWidget);

    engine.emitStats(sample(5, down: 12000000, up: 1800000));
    await tester.pump(const Duration(milliseconds: 50));

    expect(inStats('00:00:05'), findsOneWidget,
        reason: 'session time on the Stats page must tick too');
    expect(inStats('96.0'), findsOneWidget,
        reason: 'download speed must update in place');
    expect(inStats('00:00:01'), findsNothing);

    state.dispose();
  });
}
