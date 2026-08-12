import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:flutter_test/flutter_test.dart';
import 'package:veil_client/services/geo/projection.dart';
import 'package:veil_client/services/geo/world_atlas.dart';
import 'package:veil_client/theme.dart';
import 'package:veil_client/widgets/map/map_canvas.dart';

/// Set VEIL_MAP_PNG to a path to dump a render for eyeballing.
final _dump = Platform.environment['VEIL_MAP_PNG'];

const _frankfurt = Offset(8.68, 50.11);
const _stockholm = Offset(18.07, 59.33);
const _istanbul = Offset(28.98, 41.01);
const _singapore = Offset(103.82, 1.35);
const _newYork = Offset(-74.01, 40.71);

void main() {
  group('Natural Earth projection', () {
    test('matches d3.geoNaturalEarth1 at the reference points', () {
      // d3's raw projection is scale-free; these are the published polynomial
      // outputs in radians-space, which is what pins the coefficients down.
      final origin = NaturalEarth.raw(0, 0);
      expect(origin.dx, closeTo(0, 1e-9));
      expect(origin.dy, closeTo(0, 1e-9));

      // 180°E on the equator: lambda * 0.8707.
      final east = NaturalEarth.raw(180, 0);
      expect(east.dx, closeTo(3.141592653589793 * 0.8707, 1e-9));

      // Symmetry in both axes.
      final a = NaturalEarth.raw(40, 35);
      final b = NaturalEarth.raw(-40, -35);
      expect(a.dx, closeTo(-b.dx, 1e-12));
      expect(a.dy, closeTo(-b.dy, 1e-12));
    });

    test('fits the world into the box and keeps geography ordered', () {
      const size = Size(1000, 560);
      final p = NaturalEarth.fit(size);

      for (final c in [_frankfurt, _stockholm, _istanbul, _singapore, _newYork]) {
        final o = p.projectPoint(c);
        expect(o.dx, inInclusiveRange(0, size.width));
        expect(o.dy, inInclusiveRange(0, size.height));
      }

      // Stockholm is north of Frankfurt, so it must paint higher up.
      expect(p.projectPoint(_stockholm).dy,
          lessThan(p.projectPoint(_frankfurt).dy));
      // New York is west of Istanbul.
      expect(p.projectPoint(_newYork).dx,
          lessThan(p.projectPoint(_istanbul).dx));
      // Singapore is east of Istanbul and much nearer the equator.
      expect(p.projectPoint(_singapore).dx,
          greaterThan(p.projectPoint(_istanbul).dx));
      expect(p.projectPoint(_singapore).dy,
          greaterThan(p.projectPoint(_istanbul).dy));
    });

    group('fitPoints', () {
      // A representative spread of Android viewports, minus the sheet: the
      // band above it is what the phone map is fitted into, and its aspect
      // ratio is nothing like the world's.
      const viewports = [
        Size(360, 260), // small 16:9 handset
        Size(384, 300), // Pixel-ish
        Size(412, 340), // large 20:9
        Size(280, 420), // tall and narrow, folded
      ];
      const padding = EdgeInsets.only(bottom: 40);
      const points = [_frankfurt, _stockholm, _istanbul];

      test('keeps every point on screen whatever the viewport', () {
        for (final size in viewports) {
          final p = NaturalEarth.fitPoints(size, points, padding: padding);
          for (final c in points) {
            final o = p.projectPoint(c);
            expect(o.dx, inInclusiveRange(0, size.width),
                reason: '$c off the side at $size');
            expect(o.dy,
                inInclusiveRange(0, size.height - padding.bottom),
                reason: '$c under the sheet at $size');
          }
        }
      });

      test('shows the same slice of the world on every viewport', () {
        // The point of the whole thing: the framing is a function of the
        // account, not of the handset. Cover-fitting made this vary by more
        // than 2x — locations that were on screen on one phone were nowhere
        // near it on another.
        double visibleLonSpan(Size size) {
          final p = NaturalEarth.fitPoints(size, points, padding: padding);
          // Width of the viewport measured in degrees of longitude at the
          // equator, where the projection's x is linear in lambda.
          final perDegree = NaturalEarth.raw(1, 0).dx * p.scale;
          return size.width / perDegree;
        }

        final spans = viewports.map(visibleLonSpan).toList();
        for (final span in spans) {
          // Three European capitals span ~20°; anything much past a continent
          // means the fit fell back to showing the whole world.
          expect(span, inInclusiveRange(25, 130));
        }
        // And they agree with each other: a narrow phone shows a little less
        // than a wide one, not a different part of the planet.
        final widest = spans.reduce((a, b) => a > b ? a : b);
        final narrowest = spans.reduce((a, b) => a < b ? a : b);
        expect(widest / narrowest, lessThan(2.0));
      });

      test('a lone location is framed with its neighbours, not zoomed into',
          () {
        final p = NaturalEarth.fitPoints(
            const Size(384, 300), const [_frankfurt],
            padding: padding);
        final perDegree = NaturalEarth.raw(1, 0).dx * p.scale;
        expect(384 / perDegree, greaterThan(30),
            reason: 'one point must not zoom to a single city');
      });

      test('falls back to the plain fit with nothing to frame', () {
        const size = Size(384, 300);
        final a = NaturalEarth.fitPoints(size, const []);
        final b = NaturalEarth.fit(size, maxCrop: 0.35);
        expect(a.scale, b.scale);
        expect(a.translate, b.translate);
      });

      test('never leaves empty space beside the world', () {
        for (final size in viewports) {
          final p = NaturalEarth.fitPoints(size, points, padding: padding);
          final world = p.screenBounds;
          // Either the world covers the band, or it is centred in it.
          final region = Rect.fromLTRB(
              0, 0, size.width, size.height - padding.bottom);
          if (world.width >= region.width) {
            expect(world.left, lessThanOrEqualTo(region.left + 0.5));
            expect(world.right, greaterThanOrEqualTo(region.right - 0.5));
          } else {
            expect(world.center.dx, closeTo(region.center.dx, 0.5));
          }
        }
      });
    });

    test('every ring lands inside the fitted box', () {
      const size = Size(800, 460);
      final p = NaturalEarth.fit(size);
      for (final ring in worldRings()) {
        for (final c in ring) {
          final o = p.projectPoint(c);
          expect(o.dx, inInclusiveRange(-1, size.width + 1));
          expect(o.dy, inInclusiveRange(-1, size.height + 1));
        }
      }
    });
  });

  group('great circle', () {
    test('starts and ends on its endpoints', () {
      final pts = greatCircle(_istanbul, _frankfurt);
      expect(pts.first.dx, closeTo(_istanbul.dx, 1e-6));
      expect(pts.first.dy, closeTo(_istanbul.dy, 1e-6));
      expect(pts.last.dx, closeTo(_frankfurt.dx, 1e-6));
      expect(pts.last.dy, closeTo(_frankfurt.dy, 1e-6));
    });

    test('bows away from the straight line on a long route', () {
      // Istanbul to New York passes well north of the lon/lat midpoint — that
      // curvature is the whole reason for interpolating on the sphere.
      final pts = greatCircle(_istanbul, _newYork);
      final mid = pts[pts.length ~/ 2];
      final flatMid = (_istanbul.dy + _newYork.dy) / 2;
      expect(mid.dy, greaterThan(flatMid + 2));
    });

    test('handles coincident endpoints without dividing by zero', () {
      final pts = greatCircle(_frankfurt, _frankfurt);
      expect(pts.length, greaterThanOrEqualTo(2));
      for (final p in pts) {
        expect(p.dx.isFinite && p.dy.isFinite, isTrue);
      }
    });
  });

  test('distanceKm matches the known Istanbul–Frankfurt great circle', () {
    // ~1 866 km, the figure the design mockup quotes.
    expect(distanceKm(_istanbul, _frankfurt), inInclusiveRange(1830, 1900));
  });

  testWidgets('paints nodes, arc and chrome without throwing', (tester) async {
    tester.view.physicalSize = const Size(1100, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final key = GlobalKey();
    const nodes = [
      MapNode(id: 1, coords: _frankfurt, label: 'Frankfurt', cc: 'DE', ping: 23, load: 78),
      MapNode(id: 2, coords: _stockholm, label: 'Stockholm', cc: 'SE', ping: 31, load: 42),
      MapNode(id: 3, coords: _singapore, label: 'Singapore', cc: 'SG', ping: 11, load: 62),
      MapNode(id: 4, coords: _newYork, label: 'New York', cc: 'US', ping: 38, load: 71),
    ];

    await tester.pumpWidget(MaterialApp(
      theme: buildVeilTheme(),
      home: Scaffold(
        backgroundColor: VeilColors.bg,
        body: RepaintBoundary(
          key: key,
          child: const MapCanvas(
            nodes: nodes,
            home: _istanbul,
            selectedId: 1,
            arc: ArcState.connected,
            showLabels: true,
            showZoomControls: true,
          ),
        ),
      ),
    ));

    await tester.pump(const Duration(milliseconds: 900));
    expect(tester.takeException(), isNull);

    final dump = _dump;
    if (dump != null) {
      await tester.runAsync(() async {
        final boundary =
            key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final image = await boundary.toImage();
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        File(dump).writeAsBytesSync(data!.buffer.asUint8List());
      });
    }
  });
}
