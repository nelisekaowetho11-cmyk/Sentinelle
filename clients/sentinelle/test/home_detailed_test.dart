import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:veil_client/models/models.dart';
import 'package:veil_client/screens/home_screen.dart';
import 'package:veil_client/services/storage.dart';
import 'package:veil_client/services/vpn/leak_guard.dart';
import 'package:veil_client/services/vpn/vpn_engine.dart';
import 'package:veil_client/state/app_state.dart';
import 'package:veil_client/theme.dart';
import 'package:veil_client/widgets/common.dart';
import 'package:veil_client/widgets/map/map_canvas.dart';
import 'package:veil_client/widgets/tunnel_orb.dart';

import 'support/fake_engine.dart';

final _shots = Platform.environment['VEIL_SHOT_DIR'];

ServerConfig _server() => ServerConfig.fromJson({
      'id': 1,
      'tag': 'in-1',
      'name': 'Germany · Frankfurt',
      'region': 'Frankfurt',
      'country': 'DE',
      'protocol': 'vless',
      'security': 'reality',
      'network': 'tcp',
      'address': 'de-02.veil.net',
      'port': 443,
      'load': 78,
      'outbound': const {},
    });

AppState _state(FakeVpnEngine engine) {
  final s = AppState(engine: engine)..authStage = AuthStage.loggedIn;
  final server = _server();
  s.seedSource(
    servers: [server],
    origin: const ClientOrigin(ip: '85.100.1.2', country: 'TR'),
  );
  s.pings[server.id] = 23;
  return s;
}

Future<void> _shoot(WidgetTester tester, GlobalKey key, String name) async {
  final dir = _shots;
  if (dir == null) return;
  await tester.runAsync(() async {
    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage();
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    File('$dir/$name.png').writeAsBytesSync(data!.buffer.asUint8List());
  });
}

/// Mirrors main.dart, which rebuilds the whole tree from the AppState
/// notifier — without that listener nothing here would ever repaint.
Widget _host(AppState state, GlobalKey key) => MaterialApp(
      theme: buildVeilTheme(),
      home: Scaffold(
        backgroundColor: VeilColors.bg,
        body: RepaintBoundary(
          key: key,
          child: ListenableBuilder(
            listenable: state,
            builder: (context, _) =>
                HomeScreen(state: state, onPickServer: () {}),
          ),
        ),
      ),
    );

void main() {
  setUp(() async {
    // The guards are left off here on purpose: their probes open real sockets
    // with real timeouts, which a widget test cannot drive. Guard *display* is
    // exercised by feeding a report in directly.
    Storage.resetForTests();
    SharedPreferences.setMockInitialValues({
      'guard_dns': false,
      'guard_ipv6': false,
      'guard_webrtc': false,
    });
    await Storage.init();
  });

  test('detailed layout is the default', () {
    expect(Storage.I.detailedHome, isTrue);
  });

  testWidgets('detailed page shows the map, route and security panel',
      (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final engine = FakeVpnEngine();
    final state = _state(engine);
    await Storage.I.setLastServerId(1);

    final key = GlobalKey();
    await tester.pumpWidget(_host(state, key));
    await tester.pump(const Duration(milliseconds: 300));

    // Offline to begin with.
    expect(find.text('OFFLINE'), findsOneWidget);

    engine.emitState(VpnState.connected);
    engine.emitStats(const VpnStats(
      downloadSpeed: 6025000,
      uploadSpeed: 2837500,
      duration: Duration(hours: 1, minutes: 42, seconds: 18),
    ));
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.byType(MapCanvas), findsOneWidget);
    expect(find.text('CONNECTED'), findsOneWidget);
    expect(find.text('Türkiye → Frankfurt'), findsOneWidget);
    expect(find.text('SECURITY'), findsOneWidget);
    // The guards are compact chips now; the wording lives in their tooltips.
    expect(find.text('DNS'), findsOneWidget);
    expect(find.text('IPv6'), findsOneWidget);
    expect(find.text('WebRTC'), findsOneWidget);
    expect(find.text('Kill switch'), findsOneWidget);
    // Public IP shows the exit, which is the server while the tunnel is up.
    expect(find.text('de-02.veil.net'), findsWidgets);
    expect(find.text('01:42:18'), findsOneWidget);
    expect(find.text('48.2'), findsOneWidget);
    expect(find.text('22.7'), findsOneWidget);

    await _shoot(tester, key, 'home_detailed_desktop');
    state.dispose();
  });

  testWidgets('switching to simple shows the orb page', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final engine = FakeVpnEngine();
    final state = _state(engine);
    final key = GlobalKey();
    await tester.pumpWidget(_host(state, key));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byType(MapCanvas), findsOneWidget);
    expect(find.byType(TunnelOrb), findsNothing);

    await tester.tap(find.text('Simple'));
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.byType(MapCanvas), findsNothing);
    expect(find.byType(TunnelOrb), findsOneWidget);
    expect(Storage.I.detailedHome, isFalse);

    state.dispose();
  });

  testWidgets('security panel reports a leak when a probe gets through',
      (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final engine = FakeVpnEngine();
    final state = _state(engine);
    final key = GlobalKey();
    await tester.pumpWidget(_host(state, key));

    engine.emitState(VpnState.connected);
    await tester.pump(const Duration(milliseconds: 200));

    state.leaks = const LeakReport(
      dns: GuardState.verified,
      ipv6: GuardState.leaking,
      webrtc: GuardState.verified,
    );
    state.notifyListeners();
    await tester.pump(const Duration(milliseconds: 200));

    // A leak has to be obvious without reading every chip.
    expect(find.text('A guard is leaking'), findsOneWidget);
    expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);

    String tooltipFor(String label) => tester
        .widgetList<Tooltip>(find.byType(Tooltip))
        .map((t) => t.message ?? '')
        .firstWhere((m) => m.startsWith('$label ·'), orElse: () => '');

    expect(tooltipFor('IPv6'), 'IPv6 · Leaking');
    expect(tooltipFor('WebRTC'), 'WebRTC · Protected');
    expect(tooltipFor('DNS'), 'DNS · Through tunnel');

    state.dispose();
  });

  testWidgets('phone layout stacks the panels under the map', (tester) async {
    tester.view.physicalSize = const Size(393, 852);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final engine = FakeVpnEngine();
    final state = _state(engine);
    await Storage.I.setLastServerId(1);

    final key = GlobalKey();
    await tester.pumpWidget(_host(state, key));
    engine.emitState(VpnState.connected);
    engine.emitStats(const VpnStats(
      downloadSpeed: 6025000,
      uploadSpeed: 2837500,
      duration: Duration(minutes: 12, seconds: 4),
    ));
    await tester.pump(const Duration(milliseconds: 600));

    expect(tester.takeException(), isNull);
    expect(find.byType(MapCanvas), findsOneWidget);
    expect(find.text('SECURITY'), findsOneWidget);

    // The phone had no way to start or stop a tunnel from this page: the wide
    // layout's button lives in the status bar, which is button-less when
    // compact.
    expect(find.byType(PrimaryActionButton), findsOneWidget);
    expect(find.text('Disconnect'), findsOneWidget);

    await _shoot(tester, key, 'home_detailed_phone');
    state.dispose();
  });

  testWidgets('phone connect button drives the tunnel', (tester) async {
    tester.view.physicalSize = const Size(393, 852);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final engine = FakeVpnEngine()..stallConnect = true;
    final state = _state(engine);
    await tester.pumpWidget(_host(state, GlobalKey()));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Connect'), findsOneWidget);
    await tester.tap(find.byType(PrimaryActionButton));
    await tester.pump();

    // The button has to acknowledge the tap on the very next frame. It used to
    // wait for the engine — which meant a blocking latency probe and a core
    // start — so it read as a button that did nothing.
    expect(engine.connectCalls, 1);
    expect(state.isBusyConnecting, isTrue);
    // The busy label says what a tap will do, not merely what is happening.
    expect(find.textContaining('Connecting…'), findsOneWidget);
    expect(find.textContaining('Tap to cancel'), findsOneWidget);

    engine.finishConnect();
    await tester.pump(const Duration(milliseconds: 100));
    expect(state.isConnected, isTrue);
    expect(find.text('Disconnect'), findsOneWidget);

    state.dispose();
  });

  testWidgets('the connect button abandons an attempt in flight',
      (tester) async {
    // A server that never answers holds the app on "Connecting…" for the
    // engine's whole timeout. The button used to disable itself for that
    // entire window, so the only way out was to kill the app.
    tester.view.physicalSize = const Size(393, 852);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final engine = FakeVpnEngine()..stallConnect = true;
    final state = _state(engine);
    await tester.pumpWidget(_host(state, GlobalKey()));
    await tester.pump(const Duration(milliseconds: 300));

    await tester.tap(find.byType(PrimaryActionButton));
    await tester.pump();
    expect(state.isBusyConnecting, isTrue);

    // Tapping the same button again gives up rather than doing nothing.
    await tester.tap(find.byType(PrimaryActionButton));
    await tester.pump(const Duration(milliseconds: 100));

    expect(engine.disconnectCalls, 1);
    expect(engine.connectCalls, 1, reason: 'cancel must not re-dial');
    expect(state.isBusyConnecting, isFalse);
    expect(state.isConnected, isFalse);
    expect(find.text('Connect'), findsOneWidget);

    state.dispose();
  });
}
