import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:veil_client/models/models.dart';
import 'package:veil_client/screens/home_screen.dart';
import 'package:veil_client/screens/locations_screen.dart';
import 'package:veil_client/screens/stats_screen.dart';
import 'package:veil_client/services/storage.dart';
import 'package:veil_client/state/app_state.dart';
import 'package:veil_client/theme.dart';

/// Pumps the real screens with a populated AppState. Catches layout/paint
/// problems that only appear once a screen has actual data in it.
void main() {
  setUp(() async {
    Storage.resetForTests();
    // These cover the simple connect layout; the detailed one (now the
    // default) has its own suite in home_detailed_test.dart.
    SharedPreferences.setMockInitialValues({'home_detailed': false});
    await Storage.init();
  });

  Profile profile({bool canConnect = true, String status = 'active'}) =>
      Profile.fromJson({
        'id': 1,
        'name': 'Milad',
        'username': 'pvb10001',
        'email': '',
        'status': status,
        'can_connect': canConnect,
        'unlimited': false,
        'traffic_limit_gb': 50.0,
        'traffic_used_gb': 12.5,
        'traffic_left_gb': 37.5,
        'traffic_pct': 25.0,
        'expires': '2027-01-01',
        'days_left': 145,
        'ip_limit': 2,
        'speed_limit_kbps': 0,
        'note': '',
        'sub_url': 'https://panel.example.com/sub/abc',
        'owner': 'reseller1',
      });

  ServerConfig server(int id, String name, String cc) => ServerConfig.fromJson({
        'id': id,
        'tag': 'inbound-$id',
        'name': name,
        'region': '',
        'country': cc,
        'protocol': 'vless',
        'transport': 'reality',
        'network': 'tcp',
        'security': 'reality',
        'address': '10.0.0.$id',
        'port': 443,
        'link': 'vless://x',
        'outbound': {
          'tag': 'proxy',
          'protocol': 'vless',
          'settings': {
            'vnext': [
              {'address': '10.0.0.$id', 'port': 443, 'users': <Map<String, Object?>>[]}
            ]
          },
          'streamSettings': {'network': 'tcp', 'security': 'reality'},
        },
      });

  AppState populated({bool withServers = true, bool canConnect = true}) {
    final s = AppState()
      ..authStage = AuthStage.loggedIn
      ..brand = 'Bridge Panel';
    s.seedSource(
      profile: profile(canConnect: canConnect),
      servers: withServers
          ? [
              server(1, 'Germany · Frankfurt', 'DE'),
              server(2, 'Netherlands · Amsterdam', 'NL'),
              server(3, 'Local relay', ''),
            ]
          : const [],
    );
    return s;
  }

  Widget host(Widget child, {Size size = const Size(1100, 760)}) => MaterialApp(
        theme: buildVeilTheme(),
        home: MediaQuery(
          data: MediaQueryData(size: size),
          child: Scaffold(body: child),
        ),
      );

  group('HomeScreen', () {
    for (final size in const [Size(1100, 760), Size(412, 892)]) {
      testWidgets('renders at ${size.width.toInt()}x${size.height.toInt()}',
          (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final state = populated();
        await tester.pumpWidget(host(
          HomeScreen(state: state, onPickServer: () {}),
          size: size,
        ));
        await tester.pump(const Duration(milliseconds: 400));
        expect(tester.takeException(), isNull);

        // The content below the header must actually be in the tree.
        expect(find.text('Not connected'), findsOneWidget);
        expect(find.text('Connect'), findsWidgets);
        expect(find.text('DATA ALLOWANCE'), findsOneWidget);
        expect(find.text('Germany · Frankfurt'), findsOneWidget);

        state.dispose();
      });
    }

    // The connect button must always be on screen — the whole point of the
    // no-scroll layout is that you never scroll to start the tunnel.
    for (final size in const [
      Size(1100, 760),   // desktop window
      Size(1020, 660),   // desktop, short
      Size(412, 892),    // typical Android phone
      Size(360, 640),    // small/older phone
      Size(412, 732),    // phone with a large system nav bar
    ]) {
      testWidgets('connect button is visible without scrolling at '
          '${size.width.toInt()}x${size.height.toInt()}', (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final state = populated();
        await tester.pumpWidget(host(
          HomeScreen(state: state, onPickServer: () {}),
          size: size,
        ));
        await tester.pump(const Duration(milliseconds: 300));
        expect(tester.takeException(), isNull);

        // No scrollable at all on this screen.
        expect(find.byType(Scrollable), findsNothing);

        final button = find.widgetWithText(FilledButton, 'Connect');
        expect(button, findsOneWidget);
        final rect = tester.getRect(button);
        expect(rect.bottom, lessThanOrEqualTo(size.height),
            reason: 'connect button runs past the bottom edge');
        expect(rect.top, greaterThanOrEqualTo(0));

        state.dispose();
      });
    }

    testWidgets('shows the blocked banner for an inactive account',
        (tester) async {
      tester.view.physicalSize = const Size(1100, 760);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final state = populated(canConnect: false);
      state.seedSource(
        profile: state.profile,
        servers: state.servers,
        blockedReason: 'You have used all of your data allowance.',
      );
      await tester.pumpWidget(host(HomeScreen(state: state, onPickServer: () {})));
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.takeException(), isNull);
      expect(find.text('Account not active'), findsOneWidget);
      state.dispose();
    });

    testWidgets('handles an account with no servers', (tester) async {
      tester.view.physicalSize = const Size(1100, 760);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final state = populated(withServers: false);
      await tester.pumpWidget(host(HomeScreen(state: state, onPickServer: () {})));
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.takeException(), isNull);
      expect(find.textContaining('No servers assigned'), findsOneWidget);
      state.dispose();
    });
  });

  testWidgets('LocationsScreen lists every server', (tester) async {
    tester.view.physicalSize = const Size(1100, 760);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final state = populated();
    await tester.pumpWidget(host(LocationsScreen(state: state)));
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull);
    // Rows lead with the config's own name and group by continent; the place
    // is the quieter second line.
    expect(find.text('Germany · Frankfurt'), findsWidgets);
    expect(find.text('Netherlands · Amsterdam'), findsWidgets);
    expect(find.textContaining('3 servers'), findsOneWidget);
    state.dispose();
  });

  testWidgets('StatsScreen renders with an idle session', (tester) async {
    tester.view.physicalSize = const Size(1100, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final state = populated();
    await tester.pumpWidget(host(StatsScreen(state: state),
        size: const Size(1100, 900)));
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull);
    expect(find.text('Session statistics'), findsOneWidget);
    expect(find.text('Disconnected'), findsWidgets);
    state.dispose();
  });
}
