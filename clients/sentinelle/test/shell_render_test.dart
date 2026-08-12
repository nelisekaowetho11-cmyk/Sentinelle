import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:veil_client/models/models.dart';
import 'package:veil_client/screens/shell.dart';
import 'package:veil_client/services/storage.dart';
import 'package:veil_client/state/app_state.dart';
import 'package:veil_client/theme.dart';

/// Pumps the full shell (sidebar + IndexedStack of pages) the way the running
/// app composes it. HomeScreen renders fine on its own, so the shell's own
/// layout has to be exercised separately.
void main() {
  setUp(() async {
    Storage.resetForTests();
    // These cover the simple connect layout; the detailed one (now the
    // default) has its own suite in home_detailed_test.dart.
    SharedPreferences.setMockInitialValues({'home_detailed': false});
    await Storage.init();
    PackageInfo.setMockInitialValues(
      appName: 'Veil',
      packageName: 'app.veil.veil_client',
      version: '1.0.0',
      buildNumber: '1',
      buildSignature: '',
    );
  });

  AppState populated() {
    final s = AppState()
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
    s.seedSource(profile: profile, servers: [
      ServerConfig.fromJson({
        'id': 1,
        'tag': 'reality-in',
        'name': 'Germany · Frankfurt',
        'country': 'DE',
        'protocol': 'vless',
        'transport': 'reality',
        'network': 'tcp',
        'security': 'reality',
        'address': '10.0.0.1',
        'port': 443,
        'link': 'vless://x',
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
      }),
    ]);
    return s;
  }

  Future<void> pumpShell(WidgetTester tester, Size size, AppState state) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      theme: buildVeilTheme(),
      home: VeilShell(state: state),
    ));
    await tester.pump(const Duration(milliseconds: 400));
  }

  testWidgets('desktop shell shows the Connect page content', (tester) async {
    final state = populated();
    await pumpShell(tester, const Size(1100, 760), state);
    expect(tester.takeException(), isNull);

    // The sidebar.
    expect(find.text('Locations'), findsWidgets);
    expect(find.text('SUBSCRIPTION'), findsOneWidget);

    // …and, crucially, the page body next to it.
    expect(find.text('Not connected'), findsOneWidget);
    expect(find.text('DATA ALLOWANCE'), findsOneWidget);
    expect(find.text('SESSION'), findsOneWidget);
    state.dispose();
  });

  testWidgets('mobile shell shows the Connect page content', (tester) async {
    final state = populated();
    await pumpShell(tester, const Size(412, 892), state);
    expect(tester.takeException(), isNull);
    expect(find.text('Not connected'), findsOneWidget);
    expect(find.text('DATA ALLOWANCE'), findsOneWidget);
    state.dispose();
  });

  testWidgets('every tab renders without exceptions', (tester) async {
    final state = populated();
    await pumpShell(tester, const Size(1100, 800), state);

    for (final label in ['Locations', 'Stats', 'Settings', 'Connect']) {
      await tester.tap(find.text(label).first);
      await tester.pump(const Duration(milliseconds: 400));
      expect(tester.takeException(), isNull, reason: 'tab "$label" threw');
    }
    state.dispose();
  });
}
