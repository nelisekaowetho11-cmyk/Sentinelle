import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/painting.dart' show EdgeInsets;

import 'world_atlas.dart';

/// The Natural Earth projection, matching `d3.geoNaturalEarth1`.
///
/// The design mockup renders with d3's implementation, so this reproduces its
/// polynomials exactly — a different pseudocylindrical projection would put
/// the coastline and the server pins in visibly different places.
///
/// Instances are cheap and immutable; build one per layout with [fit].
class NaturalEarth {
  const NaturalEarth({required this.scale, required this.translate});

  final double scale;
  final Offset translate;

  /// Unit-plane coordinates, before scale and translation. Latitude grows
  /// upward here; screen y is flipped in [project].
  static Offset raw(double lon, double lat) {
    final lambda = lon * math.pi / 180;
    final phi = lat * math.pi / 180;
    final p2 = phi * phi;
    final p4 = p2 * p2;
    return Offset(
      lambda *
          (0.8707 -
              0.131979 * p2 +
              p4 * (-0.013791 + p4 * (0.003971 * p2 - 0.001529 * p4))),
      phi *
          (1.007226 +
              p2 * (0.015085 + p4 * (-0.044475 + 0.028874 * p2 - 0.005916 * p4))),
    );
  }

  Offset project(double lon, double lat) {
    final r = raw(lon, lat);
    return Offset(
      r.dx * scale + translate.dx,
      // Screen y grows downward, the projection's y grows north.
      -r.dy * scale + translate.dy,
    );
  }

  Offset projectPoint(LonLat p) => project(p.dx, p.dy);

  /// Fits the inhabited world into [size].
  ///
  /// [extra] scales past the fit and re-centres on [focus], which is how the
  /// phone layout crops to a region instead of showing the whole globe.
  ///
  /// [cover] fills the box and crops the overflow instead of letterboxing.
  /// A phone viewport is far taller than the world is, so a contain-fit leaves
  /// the map as a thin strip floating in dead space.
  /// [maxCrop] is the fraction of the world's width you are willing to lose in
  /// exchange for a map that fills its pane. 0 letterboxes the whole world.
  ///
  /// The world is about 2.2:1 and a desktop pane is nearer 1.3:1, so a plain
  /// contain-fit spends 40% of the height on nothing and the map reads as a
  /// thin strip floating in the middle of the page. Scaling up fixes that but
  /// pushes the edges of the Pacific out of frame, so the amount is capped
  /// here rather than left to a blind blend — at 0.22 the map grows by a
  /// quarter and roughly 11° of longitude goes off each side, which panning
  /// (clamped to the world) and fly-to-selection both bring back.
  factory NaturalEarth.fit(
    Size size, {
    EdgeInsets padding = EdgeInsets.zero,
    double extra = 1.0,
    LonLat? focus,
    bool cover = false,
    double maxCrop = 0.0,
  }) {
    final bounds = _worldBounds;
    final w = size.width - padding.horizontal;
    final h = size.height - padding.vertical;
    if (w <= 0 || h <= 0) {
      return const NaturalEarth(scale: 1, translate: Offset.zero);
    }

    final contain = math.min(w / bounds.width, h / bounds.height);
    final coverK = math.max(w / bounds.width, h / bounds.height);
    final crop = maxCrop.clamp(0.0, 0.9);
    final k = cover
        ? coverK
        // Never below the contain fit, never past cover, and never wider than
        // the crop budget allows.
        : math.max(contain, math.min(coverK, contain / (1 - crop)));
    // Centre the fitted world inside the padded box.
    var proj = NaturalEarth(
      scale: k,
      translate: Offset(
        padding.left + w / 2 - bounds.center.dx * k,
        padding.top + h / 2 + bounds.center.dy * k,
      ),
    );

    if ((extra != 1.0 || cover) && focus != null) {
      // Scale up, then slide [focus] to the middle of the box.
      final zoomed = NaturalEarth(scale: k * extra, translate: proj.translate);
      final centre = Offset(padding.left + w / 2, padding.top + h / 2);
      proj = NaturalEarth(
        scale: zoomed.scale,
        translate: zoomed.translate + (centre - zoomed.projectPoint(focus)),
      );
    }
    return proj;
  }

  /// Frames [points] — the user and their locations — inside the padded box.
  ///
  /// This exists because [fit] with `cover: true` is not reproducible across
  /// devices. Cover takes its scale from `max(w/worldWidth, h/worldHeight)`,
  /// and on a phone the height term wins by a mile: the band above the sheet is
  /// roughly square, the world is 2.2:1, so the map ends up zoomed about 2.3x
  /// past a contain fit. How much of the world that leaves on screen then
  /// depends entirely on the handset's aspect ratio — which is why "every phone
  /// shows the locations somewhere different, and most of them off screen".
  ///
  /// Framing the *data* instead makes the result a function of the account, not
  /// of the hardware: every device shows the same locations, only the scale
  /// differs by however much the viewport differs.
  ///
  /// [margin] is the fraction of the box kept clear around the outermost point
  /// so pins are never welded to an edge. [maxCrop] floors the zoom at the same
  /// crop-limited fit [fit] uses, so a worldwide account still fills the band
  /// instead of sitting in it as a strip. [maxZoom] ceilings it, so an account
  /// with one location does not end up looking at a single city.
  factory NaturalEarth.fitPoints(
    Size size,
    List<LonLat> points, {
    EdgeInsets padding = EdgeInsets.zero,
    double margin = 0.12,
    double maxCrop = 0.35,
    double maxZoom = 7.0,
  }) {
    final base = NaturalEarth.fit(size, padding: padding, maxCrop: maxCrop);
    final w = size.width - padding.horizontal;
    final h = size.height - padding.vertical;
    if (points.isEmpty || w <= 0 || h <= 0) return base;

    var minX = double.infinity, minY = double.infinity;
    var maxX = double.negativeInfinity, maxY = double.negativeInfinity;
    for (final p in points) {
      final r = raw(p.dx, p.dy);
      if (r.dx < minX) minX = r.dx;
      if (r.dx > maxX) maxX = r.dx;
      if (r.dy < minY) minY = r.dy;
      if (r.dy > maxY) maxY = r.dy;
    }

    // A single location — or several in one city — has no extent, and asking
    // to fit a point is asking for infinite zoom. These floors are about 40° of
    // longitude and 24° of latitude, enough to show the neighbours.
    const minSpanX = 0.60, minSpanY = 0.42;
    final spanX = math.max(maxX - minX, minSpanX);
    final spanY = math.max(maxY - minY, minSpanY);

    final clear = margin.clamp(0.0, 0.4);
    final k = math
        .min(w * (1 - 2 * clear) / spanX, h * (1 - 2 * clear) / spanY)
        .clamp(base.scale, base.scale * maxZoom);

    // Put the middle of the points in the middle of the padded box…
    final cx = (minX + maxX) / 2, cy = (minY + maxY) / 2;
    final centre = Offset(padding.left + w / 2, padding.top + h / 2);
    var tx = centre.dx - cx * k;
    var ty = centre.dy + cy * k;

    // …then slide back so the drawn world still covers the box. Without this a
    // location near the edge of the map (New Zealand, Alaska) centres itself
    // and leaves half the pane empty.
    final b = _worldBounds;
    double axis(double t, double lo, double hi, double from, double to) {
      // [lo, hi] are the world's extent on this axis in screen space, before t.
      final extent = hi - lo;
      final span = to - from;
      if (extent <= span) return from + (span - extent) / 2 - lo;
      return t.clamp(to - (lo + extent), from - lo);
    }

    tx = axis(tx, b.left * k, b.right * k, padding.left,
        padding.left + w);
    ty = axis(ty, -b.bottom * k, -b.top * k, padding.top, padding.top + h);

    return NaturalEarth(scale: k.toDouble(), translate: Offset(tx, ty));
  }

  /// The drawn world as a rectangle in this projection's own screen space,
  /// before any viewport zoom or pan is applied.
  ///
  /// Panning clamps against this: a `cover` fit deliberately overflows the box,
  /// and without knowing by how much the map could either refuse to move or
  /// slide off into empty space.
  Rect get screenBounds {
    final b = _worldBounds;
    // y is flipped by [project], so the projection's top edge is maxY.
    final topLeft = Offset(
      b.left * scale + translate.dx,
      -b.bottom * scale + translate.dy,
    );
    final bottomRight = Offset(
      b.right * scale + translate.dx,
      -b.top * scale + translate.dy,
    );
    return Rect.fromPoints(topLeft, bottomRight);
  }

  /// Bounds of the projected world, in unit-plane space. Computed from the
  /// real ring data rather than the analytic extent, so the fit matches what
  /// is actually drawn (no Antarctica, no empty southern band).
  static Rect get _worldBounds => _bounds ??= _computeBounds();
  static Rect? _bounds;

  static Rect _computeBounds() {
    var minX = double.infinity, minY = double.infinity;
    var maxX = double.negativeInfinity, maxY = double.negativeInfinity;
    for (final ring in worldRings()) {
      for (final p in ring) {
        final r = raw(p.dx, p.dy);
        if (r.dx < minX) minX = r.dx;
        if (r.dx > maxX) maxX = r.dx;
        if (r.dy < minY) minY = r.dy;
        if (r.dy > maxY) maxY = r.dy;
      }
    }
    return Rect.fromLTRB(minX, minY, maxX, maxY);
  }
}

/// Samples the great circle from [a] to [b].
///
/// Mirrors `d3.geoInterpolate`: the line has to be spherically correct or it
/// will not bend the way a real route does under a curved projection.
List<LonLat> greatCircle(LonLat a, LonLat b, {int samples = 96}) {
  const d2r = math.pi / 180, r2d = 180 / math.pi;
  final phi0 = a.dy * d2r, lam0 = a.dx * d2r;
  final phi1 = b.dy * d2r, lam1 = b.dx * d2r;

  final cy0 = math.cos(phi0), sy0 = math.sin(phi0);
  final cy1 = math.cos(phi1), sy1 = math.sin(phi1);
  final kx0 = cy0 * math.cos(lam0), ky0 = cy0 * math.sin(lam0);
  final kx1 = cy1 * math.cos(lam1), ky1 = cy1 * math.sin(lam1);

  final d = 2 *
      math.asin(math.sqrt(
        _hav(phi1 - phi0) + cy0 * cy1 * _hav(lam1 - lam0),
      ));
  final sd = math.sin(d);

  // Coincident endpoints: no arc to draw.
  if (d == 0 || sd == 0) return [a, b];

  final out = <LonLat>[];
  for (var i = 0; i <= samples; i++) {
    final t = i / samples;
    final aa = math.sin((1 - t) * d) / sd;
    final bb = math.sin(t * d) / sd;
    final x = aa * kx0 + bb * kx1;
    final y = aa * ky0 + bb * ky1;
    final z = aa * sy0 + bb * sy1;
    out.add(Offset(
      math.atan2(y, x) * r2d,
      math.atan2(z, math.sqrt(x * x + y * y)) * r2d,
    ));
  }
  return out;
}

double _hav(double x) {
  final s = math.sin(x / 2);
  return s * s;
}

/// Great-circle distance in kilometres.
int distanceKm(LonLat a, LonLat b) {
  const r = 6371.0, d2r = math.pi / 180;
  final dLat = (b.dy - a.dy) * d2r, dLon = (b.dx - a.dx) * d2r;
  final h = _hav(dLat) +
      math.cos(a.dy * d2r) * math.cos(b.dy * d2r) * _hav(dLon);
  return (2 * r * math.asin(math.sqrt(h.clamp(0.0, 1.0)))).round();
}

/// Meridians and parallels every [step] degrees, as polylines in lon/lat.
///
/// Densely sampled along the curve so they stay smooth once projected.
List<List<LonLat>> graticule({double step = 20}) {
  final lines = <List<LonLat>>[];
  for (var lon = -180.0; lon <= 180; lon += step) {
    lines.add([
      for (var lat = -84.0; lat <= 84.0; lat += 3) Offset(lon, lat),
    ]);
  }
  for (var lat = -80.0; lat <= 80.0; lat += step) {
    lines.add([
      for (var lon = -180.0; lon <= 180.0; lon += 3) Offset(lon, lat),
    ]);
  }
  return lines;
}

/// The outline of the projected globe, used as a faint frame.
List<LonLat> sphereOutline() => [
      for (var lat = -84.0; lat <= 84.0; lat += 2) Offset(-180, lat),
      for (var lon = -180.0; lon <= 180.0; lon += 3) Offset(lon, 84),
      for (var lat = 84.0; lat >= -84.0; lat -= 2) Offset(180, lat),
      for (var lon = 180.0; lon >= -180.0; lon -= 3) Offset(lon, -84),
    ];
