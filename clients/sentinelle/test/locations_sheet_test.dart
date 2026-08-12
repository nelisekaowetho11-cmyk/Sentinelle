// Regressions for the phone location picker: the sheet used to be immovable,
// and touching the map yanked it out of position.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:veil_client/models/models.dart';
import 'package:veil_client/screens/locations_screen.dart';
import 'package:veil_client/services/storage.dart';
import 'package:veil_client/state/app_state.dart';
import 'package:veil_client/theme.dart';
import 'package:veil_client/widgets/map/map_canvas.dart';

import 'support/fake_engine.dart';

ServerConfig _s(int i) => ServerConfig.fromJson({
      'id': i,
      'name': 'City $i · Country',
      'country': 'DE',
      'protocol': 'vless',
      'network': 'tcp',
      'security': 'reality',
      'address': '10.0.0.$i',
      'port': 443,
      'outbound': const {},
    });

void main() {
  group('pan clamping', () {
    // A world fitted into the band above the sheet: shorter than the box.
    const region = Rect.fromLTRB(0, 0, 393, 409);
    const world = Rect.fromLTRB(-250, 0, 643, 409);

    test('keeps the world inside the padded band, not the whole box', () {
      final clamped = clampPanToRegion(
        pan: const Offset(0, -120),
        k: 1,
        world: world,
        region: region,
      );
      // Vertically the world exactly fills the band, so it must stay pinned to
      // the band's top — dropping it to the middle of the screen is the bug.
      expect(clamped.dy, closeTo(0, 0.01));
    });

    test('a drag past the edge stops at the edge instead of revealing void',
        () {
      final farLeft = clampPanToRegion(
        pan: const Offset(9999, 0),
        k: 1,
        world: world,
        region: region,
      );
      expect(farLeft.dx, closeTo(250, 0.01));

      final farRight = clampPanToRegion(
        pan: const Offset(-9999, 0),
        k: 1,
        world: world,
        region: region,
      );
      expect(farRight.dx, closeTo(393 - 643, 0.01));
    });

    test('panning within range is left alone', () {
      final clamped = clampPanToRegion(
        pan: const Offset(100, 0),
        k: 1,
        world: world,
        region: region,
      );
      expect(clamped.dx, closeTo(100, 0.01));
    });
  });

  group('phone sheet', () {
    setUp(() async {
      Storage.resetForTests();
      SharedPreferences.setMockInitialValues({});
      await Storage.init();
    });

    Future<AppState> pumpPicker(WidgetTester tester) async {
      tester.view.physicalSize = const Size(393, 852);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final state = AppState(engine: FakeVpnEngine())
        ..authStage = AuthStage.loggedIn;
      state.seedSource(
        servers: [for (var i = 1; i <= 10; i++) _s(i)],
        origin: const ClientOrigin(ip: '1.2.3.4', country: 'TR'),
      );

      await tester.pumpWidget(MaterialApp(
        theme: buildVeilTheme(),
        home: Scaffold(body: LocationsScreen(state: state)),
      ));
      await tester.pump(const Duration(milliseconds: 600));
      return state;
    }

    double sheetTop(WidgetTester tester) => tester
        .getRect(find
            .descendant(
              of: find.byType(DraggableScrollableSheet),
              matching: find.byType(DecoratedBox),
            )
            .first)
        .top;

    testWidgets('touching the map leaves the sheet where it is',
        (tester) async {
      final state = await pumpPicker(tester);
      final before = sheetTop(tester);

      await tester.dragFrom(const Offset(200, 120), const Offset(0, 40));
      await tester.pump(const Duration(milliseconds: 400));
      expect(sheetTop(tester), closeTo(before, 0.5));

      await tester.tapAt(const Offset(200, 150));
      await tester.pump(const Duration(milliseconds: 400));
      expect(sheetTop(tester), closeTo(before, 0.5));

      state.dispose();
    });

    testWidgets('the grab handle raises and lowers the sheet', (tester) async {
      final state = await pumpPicker(tester);
      final resting = sheetTop(tester);

      // Dragging the handle used to do nothing at all: the sheet only
      // responded to its own list scrolling.
      await tester.dragFrom(Offset(196, resting + 12), const Offset(0, -250));
      await tester.pump(const Duration(milliseconds: 500));
      final raised = sheetTop(tester);
      expect(raised, lessThan(resting - 100));

      await tester.dragFrom(Offset(196, raised + 12), const Offset(0, 250));
      await tester.pump(const Duration(milliseconds: 500));
      expect(sheetTop(tester), greaterThan(raised + 100));

      state.dispose();
    });

    testWidgets('scrolling the list grows the sheet', (tester) async {
      final state = await pumpPicker(tester);
      final resting = sheetTop(tester);

      await tester.dragFrom(const Offset(200, 700), const Offset(0, -200));
      await tester.pump(const Duration(milliseconds: 500));
      expect(sheetTop(tester), lessThan(resting));

      state.dispose();
    });
  });
}
