import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:veil_client/models/models.dart';
import 'package:veil_client/screens/home_screen.dart';
import 'package:veil_client/services/storage.dart';
import 'package:veil_client/services/vpn/desktop_engine.dart';
import 'package:veil_client/services/vpn/vpn_engine.dart';
import 'package:veil_client/state/app_state.dart';
import 'package:veil_client/theme.dart';
import 'package:veil_client/widgets/error_panel.dart';

import 'support/fake_engine.dart';

ServerConfig _server() => ServerConfig.fromJson({
      'id': 1,
      'name': 'Germany · Frankfurt',
      'country': 'DE',
      'protocol': 'vless',
      'network': 'tcp',
      'security': 'reality',
      'address': 'de-02.veil.net',
      'port': 443,
      'outbound': const {},
    });

void main() {
  setUp(() async {
    Storage.resetForTests();
    SharedPreferences.setMockInitialValues({
      'guard_dns': false,
      'guard_ipv6': false,
      'guard_webrtc': false,
      'guard_timezone': false,
    });
    await Storage.init();
  });

  group('core exit diagnosis', () {
    test('a port clash names the ports, not the exit code', () {
      final m = DesktopVpnEngine.diagnose(
        1,
        'FATAL[0000] listen tcp 127.0.0.1:10808: bind: Only one usage of each '
            'socket address is normally permitted.',
        TunnelMode.proxy,
      );
      expect(m, contains('local ports'));
      expect(m, isNot(contains('exit code')));
    });

    test('a permission failure in VPN mode points at elevation', () {
      final m = DesktopVpnEngine.diagnose(
        1,
        'FATAL[0000] create tun interface: Access is denied.',
        TunnelMode.vpn,
      );
      expect(m.toLowerCase(), contains('administrator'));
    });

    test('a handshake failure points at the REALITY dest', () {
      final m = DesktopVpnEngine.diagnose(
        1,
        'ERROR[0003] outbound/vless: reality handshake failed',
        TunnelMode.proxy,
      );
      expect(m, contains('dest'));
    });

    test('an unrecognised failure still reports the exit code', () {
      final m = DesktopVpnEngine.diagnose(3, 'something odd', TunnelMode.proxy);
      expect(m, contains('exit code 3'));
    });
  });

  testWidgets('an engine failure reaches the connect page with its reason',
      (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final engine = FakeVpnEngine();
    final state = AppState(engine: engine)..authStage = AuthStage.loggedIn;
    state.seedSource(servers: [_server()]);

    await tester.pumpWidget(MaterialApp(
      theme: buildVeilTheme(),
      home: Scaffold(
        body: ListenableBuilder(
          listenable: state,
          builder: (context, _) =>
              HomeScreen(state: state, onPickServer: () {}),
        ),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(ErrorPanel), findsNothing);

    // What the user hit: the core came up and then died.
    engine.emitState(VpnState.connected);
    await tester.pump(const Duration(milliseconds: 100));
    engine.lastFailure =
        'Another program is already using one of the local ports.';
    engine.emitState(VpnState.error);
    await tester.pump(const Duration(milliseconds: 300));

    // Previously this was the bare word "ERROR" and nothing else.
    expect(find.byType(ErrorPanel), findsOneWidget);
    expect(find.text('Could not connect'), findsOneWidget);
    expect(
      find.text('Another program is already using one of the local ports.'),
      findsOneWidget,
    );

    // And it can be dismissed without touching the tunnel.
    await tester.tap(find.byIcon(Icons.close_rounded));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byType(ErrorPanel), findsNothing);

    state.dispose();
  });
}
