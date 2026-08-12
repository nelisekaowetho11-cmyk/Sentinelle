import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:veil_client/models/models.dart';
import 'package:veil_client/screens/locations_screen.dart';
import 'package:veil_client/services/storage.dart';
import 'package:veil_client/state/app_state.dart';
import 'package:veil_client/theme.dart';
import 'package:veil_client/widgets/map/map_canvas.dart';
import 'package:veil_client/widgets/map/server_nodes.dart';

import 'support/fake_engine.dart';

/// Set VEIL_SHOT_DIR to dump renders for eyeballing.
final _shots = Platform.environment['VEIL_SHOT_DIR'];

ServerConfig server(
  int id,
  String name,
  String cc, {
  String region = '',
  int? load,
}) =>
    ServerConfig.fromJson({
      'id': id,
      'tag': 'in-$id',
      'name': name,
      'region': region,
      'country': cc,
      'protocol': 'vless',
      'transport': 'reality',
      'network': 'tcp',
      'security': 'reality',
      'address': '${cc.toLowerCase()}-0$id.veil.net',
      'port': 443,
      'link': '',
      'load': ?load,
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

final _servers = [
  server(1, 'Germany · Frankfurt', 'DE', region: 'Frankfurt', load: 78),
  server(2, 'Netherlands · Amsterdam', 'NL', region: 'Amsterdam', load: 54),
  server(3, 'Sweden · Stockholm', 'SE', region: 'Stockholm', load: 42),
  server(4, 'United Kingdom · London', 'GB', region: 'London', load: 61),
  server(5, 'Singapore', 'SG', region: 'Singapore', load: 62),
  server(6, 'Japan · Tokyo', 'JP', region: 'Tokyo', load: 34),
  server(7, 'United States · New York', 'US', region: 'New York', load: 71),
  server(8, 'Brazil · São Paulo', 'BR', region: 'Sao Paulo', load: 22),
];

/// Looks a seeded server up by city, because [ServerConfig.id] is a hash of
/// the source-scoped uid rather than the panel's own numbering.
int _idOf(String city) => _servers.firstWhere((s) => s.city == city).id;

AppState _state(FakeVpnEngine engine) {
  final s = AppState(engine: engine)
    ..authStage = AuthStage.loggedIn
    ..brand = 'Panel';
  s.seedSource(
    servers: _servers,
    origin: const ClientOrigin(ip: '85.100.1.2', country: 'TR'),
  );
  const latencies = [23, 26, 31, 28, 11, 18, 38, 88];
  for (var i = 0; i < _servers.length; i++) {
    s.pings[_servers[i].id] = latencies[i];
  }
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

void main() {
  setUp(() async {
    Storage.resetForTests();
    SharedPreferences.setMockInitialValues({});
    await Storage.init();
  });

  group('server placement', () {
    test('prefers panel coordinates, then city, then country centroid', () {
      // Exact coordinates win outright.
      final exact = ServerConfig.fromJson({
        'id': 1, 'country': 'DE', 'lat': 12.5, 'lon': 34.5, 'outbound': {},
      });
      expect(serverCoords(exact), const Offset(34.5, 12.5));

      // A recognised city beats the country centroid.
      final city = server(2, 'Germany · Frankfurt', 'DE', region: 'Frankfurt');
      expect(serverCoords(city), const Offset(8.68, 50.11));

      // Unknown region falls back to the middle of the country.
      final country = server(3, 'Germany · Somewhere', 'DE');
      expect(serverCoords(country), countryCentroid['DE']);

      // Nothing at all is still placed rather than dropped.
      final nowhere = ServerConfig.fromJson({'id': 4, 'outbound': {}});
      expect(serverCoords(nowhere), isNull);
    });

    test('city extraction copes with the panel naming styles', () {
      expect(server(1, 'Germany · Frankfurt', 'DE').city, 'Frankfurt');
      expect(server(2, 'Germany - Berlin', 'DE').city, 'Berlin');
      expect(server(3, 'Solo', 'DE', region: 'Munich').city, 'Munich');
    });

    test('co-located servers are spread so each stays clickable', () {
      final same = [
        server(1, 'DE one', 'DE', region: 'Frankfurt'),
        server(2, 'DE two', 'DE', region: 'Frankfurt'),
        server(3, 'DE three', 'DE', region: 'Frankfurt'),
      ];
      final nodes = buildNodes(same, pings: const {});
      for (var i = 0; i < nodes.length; i++) {
        for (var j = i + 1; j < nodes.length; j++) {
          expect((nodes[i].coords - nodes[j].coords).distance, greaterThan(1.0),
              reason: 'nodes ${nodes[i].id} and ${nodes[j].id} overlap');
        }
      }
    });

    test('servers with no known position still get a node', () {
      final nodes = buildNodes(
        [ServerConfig.fromJson({'id': 9, 'name': 'Mystery', 'outbound': {}})],
        pings: const {},
      );
      expect(nodes, hasLength(1));
      expect(nodes.first.coords.dx.isFinite, isTrue);
    });

    test('continent grouping covers every country we place', () {
      for (final cc in countryCentroid.keys) {
        expect(continentOrder, contains(continentOf(cc)),
            reason: '$cc has no continent bucket');
      }
    });
  });

  group('picker', () {
    testWidgets('desktop shows the list, HUD and dock', (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final engine = FakeVpnEngine();
      final state = _state(engine);
      await Storage.I.setLastServerId(1);

      final key = GlobalKey();
      await tester.pumpWidget(MaterialApp(
        theme: buildVeilTheme(),
        home: Scaffold(
          backgroundColor: VeilColors.bg,
          body: RepaintBoundary(key: key, child: LocationsScreen(state: state)),
        ),
      ));
      await tester.pump(const Duration(milliseconds: 900));

      expect(tester.takeException(), isNull);
      expect(find.byType(MapCanvas), findsOneWidget);
      // Group headings, a row, the HUD and the dock's action. Rows lead with
      // the config's own name, not the place it happens to be in.
      expect(find.text('EUROPE'), findsOneWidget);
      expect(find.text('Germany · Frankfurt'), findsWidgets);
      expect(find.text('SELECTED'), findsOneWidget);
      expect(find.text('Connect'), findsOneWidget);

      await _shoot(tester, key, 'locations_desktop');
      state.dispose();
    });

    testWidgets('search narrows the list and dims the map', (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final engine = FakeVpnEngine();
      final state = _state(engine);
      await tester.pumpWidget(MaterialApp(
        theme: buildVeilTheme(),
        home: Scaffold(body: LocationsScreen(state: state)),
      ));
      await tester.pump(const Duration(milliseconds: 400));

      await tester.enterText(find.byType(TextField).first, 'tokyo');
      await tester.pump(const Duration(milliseconds: 200));

      // Asserted on the row's place line rather than its name: the dock and
      // the HUD both keep naming the *selected* server, which is Frankfurt,
      // whatever the list is filtered to.
      expect(find.text('Frankfurt · Germany'), findsNothing);
      expect(find.text('Japan · Tokyo'), findsWidgets);
      expect(find.text('Tokyo · Japan'), findsWidgets);

      final map = tester.widget<MapCanvas>(find.byType(MapCanvas));
      final tokyo = map.nodes.firstWhere((n) => n.id == _idOf('Tokyo'));
      final frankfurt = map.nodes.firstWhere((n) => n.id == _idOf('Frankfurt'));
      expect(tokyo.dimmed, isFalse);
      expect(frankfurt.dimmed, isTrue,
          reason: 'filtered-out nodes should fade on the map, not vanish');

      state.dispose();
    });

    testWidgets('favourites filter uses the stored stars', (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      // Ids are derived from the source-scoped uid now, so ask the list
      // rather than assuming the panel's numbering.
      await Storage.I.toggleFavourite(_idOf('Singapore'));
      final engine = FakeVpnEngine();
      final state = _state(engine);
      await tester.pumpWidget(MaterialApp(
        theme: buildVeilTheme(),
        home: Scaffold(body: LocationsScreen(state: state)),
      ));
      await tester.pump(const Duration(milliseconds: 400));

      await tester.tap(find.text('Favourites'));
      await tester.pump(const Duration(milliseconds: 250));

      expect(find.text('Singapore'), findsWidgets);
      expect(find.text('Frankfurt'), findsNothing);

      state.dispose();
    });

    testWidgets('a row shows the config name, not its GeoIP country',
        (tester) async {
      // The panel fills `region` from GeoIP, and for most inbounds that is the
      // country and nothing else. The picker used to lead with it, so an
      // inbound the operator called "Alpha-01" was listed as "Germany" — and
      // every German inbound looked like the same row repeated.
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final engine = FakeVpnEngine();
      final state = AppState(engine: engine)..authStage = AuthStage.loggedIn;
      state.seedSource(servers: [
        server(1, 'Alpha-01', 'DE', region: 'Germany'),
        server(2, 'Beta-02', 'DE', region: 'Germany'),
      ]);

      await tester.pumpWidget(MaterialApp(
        theme: buildVeilTheme(),
        home: Scaffold(body: LocationsScreen(state: state)),
      ));
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('Alpha-01'), findsWidgets);
      expect(find.text('Beta-02'), findsWidgets);
      // The place is still there, underneath — and says "Germany" once, not
      // "Germany · Germany".
      expect(find.text('Germany'), findsWidgets);
      expect(find.textContaining('Germany · Germany'), findsNothing);

      state.dispose();
    });

    testWidgets('tapping a row selects that server', (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final engine = FakeVpnEngine();
      final state = _state(engine);
      await tester.pumpWidget(MaterialApp(
        theme: buildVeilTheme(),
        home: Scaffold(body: LocationsScreen(state: state)),
      ));
      await tester.pump(const Duration(milliseconds: 400));

      await tester.tap(find.text('Sweden · Stockholm').first);
      await tester.pump(const Duration(milliseconds: 400));

      expect(Storage.I.lastServerId, _idOf('Stockholm'));
      state.dispose();
    });

    testWidgets('phone shows the map behind a scrollable sheet', (tester) async {
      tester.view.physicalSize = const Size(393, 852);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final engine = FakeVpnEngine();
      final state = _state(engine);
      await Storage.I.setLastServerId(1);

      final key = GlobalKey();
      await tester.pumpWidget(MaterialApp(
        theme: buildVeilTheme(),
        home: Scaffold(
          backgroundColor: VeilColors.bg,
          body: RepaintBoundary(key: key, child: LocationsScreen(state: state)),
        ),
      ));
      await tester.pump(const Duration(milliseconds: 900));

      expect(tester.takeException(), isNull);
      expect(find.byType(MapCanvas), findsOneWidget);
      expect(find.text('Choose location'), findsOneWidget);
      expect(find.textContaining('Connect to'), findsOneWidget);

      // The list scrolls even though no scrollbar is painted.
      expect(find.byType(Scrollbar), findsNothing);
      await tester.drag(find.text('EUROPE'), const Offset(0, -120));
      await tester.pump(const Duration(milliseconds: 200));
      expect(tester.takeException(), isNull);

      await _shoot(tester, key, 'locations_phone');
      state.dispose();
    });
  });
}
