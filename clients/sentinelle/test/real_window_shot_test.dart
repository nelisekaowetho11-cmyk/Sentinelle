// Renders the shell at the size the desktop app actually runs at.
//
// The other render tests use a roomy 1280x800; the real window is a fixed
// 1020x700 with a sidebar, and that is where "the map is small" comes from.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:veil_client/models/models.dart';
import 'package:veil_client/screens/locations_screen.dart';
import 'package:veil_client/screens/shell.dart';
import 'package:veil_client/services/storage.dart';
import 'package:veil_client/state/app_state.dart';
import 'package:veil_client/theme.dart';

import 'support/fake_engine.dart';

final _shots = Platform.environment['VEIL_SHOT_DIR'];

ServerConfig _server(int id, String name, String cc) => ServerConfig.fromJson({
      'id': id,
      'tag': 'in-$id',
      'name': name,
      'country': cc,
      'protocol': 'vless',
      'network': 'tcp',
      'security': 'reality',
      'address': '10.0.0.$id',
      'port': 443,
      'outbound': const {},
    });

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

void main() {
  setUp(() async {
    // The desktop shell draws its own title bar, which asks window_manager
    // whether the window is maximised. No plugin here, so answer for it.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('window_manager'),
      (call) async => call.method == 'isMaximized' ? false : null,
    );
    Storage.resetForTests();
    SharedPreferences.setMockInitialValues({
      'guard_dns': false,
      'guard_ipv6': false,
      'guard_webrtc': false,
      'guard_timezone': false,
    });
    await Storage.init();
    // The Settings screen reads its version on the first frame.
    PackageInfo.setMockInitialValues(
      appName: 'Sentinelle',
      packageName: 'app.veil.veil_client',
      version: '1.4.0',
      buildNumber: '7',
      buildSignature: '',
    );
  });

  Future<AppState> makeState() async {
    final s = AppState(engine: FakeVpnEngine())
      ..authStage = AuthStage.loggedIn
      ..brand = 'Sentinelle';
    s.seedSource(servers: [
      _server(1, 'Germany · Frankfurt', 'DE'),
      _server(2, 'Netherlands · Amsterdam', 'NL'),
      _server(3, 'Sweden · Stockholm', 'SE'),
      _server(4, 'Japan · Tokyo', 'JP'),
    ], origin: const ClientOrigin(ip: '85.100.1.2', country: 'TR'));
    return s;
  }

  Future<void> pump(
    WidgetTester tester,
    AppState state,
    GlobalKey key, {
    Brightness brightness = Brightness.dark,
  }) async {
    // The real window: fixed 1020x700, minus the custom title bar.
    tester.view.physicalSize = const Size(1020, 660);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    // The palette is global, so it has to be set before the tree is built —
    // exactly as the app root does it.
    VeilTheme.apply(brightness);
    addTearDown(() => VeilTheme.apply(Brightness.dark));
    await tester.pumpWidget(MaterialApp(
      theme: buildVeilTheme(brightness),
      home: RepaintBoundary(
        key: key,
        child: ListenableBuilder(
          listenable: state,
          builder: (context, _) => VeilShell(state: state),
        ),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 500));
  }

  testWidgets('real window — connect page', (tester) async {
    final state = await makeState();
    final key = GlobalKey();
    await pump(tester, state, key);
    expect(tester.takeException(), isNull);
    await _shoot(tester, key, 'real_connect_expanded');

    // Collapse the sidebar and shoot again.
    await tester.tap(find.byIcon(Icons.keyboard_double_arrow_left_rounded));
    // Implicit animations need a frame to pick up the new value and another to
    // run: a single long pump leaves AnimatedContainer at its start width.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(Storage.I.sidebarCollapsed, isTrue);

    // The whole point is the space it gives back.
    final width = tester.getSize(find.byType(VeilShell)).width;
    final sidebar = tester.getSize(
      find.descendant(
        of: find.byType(VeilShell),
        matching: find.byType(AnimatedContainer),
      ).first,
    );
    expect(sidebar.width, lessThan(80),
        reason: 'collapsed sidebar should be an icon rail, not a panel');
    expect(width - sidebar.width, greaterThan(930));
    await _shoot(tester, key, 'real_connect_collapsed');

    state.dispose();
  });

  // Light mode is a whole second palette, and the only honest way to know it
  // holds together is to render it and look.
  testWidgets('real window — light theme', (tester) async {
    final state = await makeState();
    final key = GlobalKey();
    await pump(tester, state, key, brightness: Brightness.light);
    expect(tester.takeException(), isNull);
    await _shoot(tester, key, 'light_connect');

    await tester.tap(find.byIcon(Icons.tune_rounded));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(tester.takeException(), isNull);
    await _shoot(tester, key, 'light_settings');

    await tester.tap(find.byIcon(Icons.public_rounded));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(tester.takeException(), isNull);
    await _shoot(tester, key, 'light_locations');

    state.dispose();
  });

  testWidgets('real window — locations page', (tester) async {
    final state = await makeState();
    final key = GlobalKey();
    await pump(tester, state, key);
    await tester.tap(find.byIcon(Icons.public_rounded));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(tester.takeException(), isNull);
    // Prove we are actually looking at the picker before shooting it.
    expect(find.byType(LocationsScreen), findsOneWidget);
    await _shoot(tester, key, 'real_locations');
    state.dispose();
  });
}
