import 'dart:math' as math;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/gestures.dart' show PointerScrollEvent;
import 'package:flutter/material.dart';

import '../../services/geo/projection.dart';
import '../../services/geo/world_atlas.dart';
import '../../theme.dart';

/// One selectable location on the map.
class MapNode {
  const MapNode({
    required this.id,
    required this.coords,
    required this.label,
    this.name = '',
    this.cc = '',
    this.ping,
    this.load = 0,
    this.offline = false,
    this.dimmed = false,
    this.subtitle = '',
  });

  final Object id;
  final LonLat coords;

  /// Short place name drawn beside the node when labels are on. Kept short on
  /// purpose — this is 9.5px type sitting on top of the coastline.
  final String label;

  /// What the config is actually called, for the tooltip. The pin label is a
  /// place; this is the thing the user picked it by.
  final String name;
  final String cc;

  /// Round-trip latency in ms; null when never measured, negative when it
  /// failed.
  final int? ping;

  /// 0-100. Above 75 the node paints amber, matching the mockup's "busy".
  final int load;
  final bool offline;

  /// Filtered out by search: drawn faint and not clickable.
  final bool dimmed;
  final String subtitle;

  bool get busy => load > 75;
}

/// Keeps [world] covering [region] as the viewport is panned.
///
/// Separated out because getting it wrong is invisible until someone drags:
/// clamping against the whole box rather than the padded region meant a world
/// fitted into the band above the phone's sheet was shorter than the box, hit
/// the "centre it" branch, and jumped down the screen the instant it was
/// touched — leaving a gap along the top.
Offset clampPanToRegion({
  required Offset pan,
  required double k,
  required Rect world,
  required Rect region,
}) {
  double axis(double value, double left, double extent, double min, double max) {
    final scaledLeft = left * k;
    final scaledExtent = extent * k;
    final span = max - min;
    if (scaledExtent <= span) {
      // Smaller than the region: hold it centred rather than let it wander.
      return min + (span - scaledExtent) / 2 - scaledLeft;
    }
    // Leading edge no further in than the region's start, trailing edge no
    // further out than its end.
    return value.clamp(max - (scaledLeft + scaledExtent), min - scaledLeft);
  }

  return Offset(
    axis(pan.dx, world.left, world.width, region.left, region.right),
    axis(pan.dy, world.top, world.height, region.top, region.bottom),
  );
}

/// How the connection line should read.
enum ArcState {
  /// No line.
  none,

  /// Drawn, but this is only a selection — the tunnel is not up.
  selected,

  /// Amber and pulsing.
  connecting,

  /// Solid accent with a travelling packet.
  connected,
}

/// The animated world map shared by the location picker and the connect page.
///
/// Everything is painted rather than composed from widgets: at 7x zoom with a
/// spinning ring, a travelling packet and per-node ping rings, a widget per
/// marker would rebuild the tree on every frame. Painting also makes the
/// counter-scaling trivial — markers are drawn at a fixed pixel size no matter
/// what the zoom is, exactly like the mockup's `1/k` radii.
class MapCanvas extends StatefulWidget {
  const MapCanvas({
    super.key,
    required this.nodes,
    this.home,
    this.selectedId,
    this.onSelect,
    this.onNodeTap,
    this.arc = ArcState.none,
    this.showLabels = false,
    this.interactive = true,
    this.showZoomControls = false,
    this.showTooltip = true,
    this.focus,
    this.zoomExtra = 1.0,
    this.padding = EdgeInsets.zero,
    this.flyToSelection = false,
    this.cover = false,
    this.maxCrop = 0.0,
    this.fitPoints = const [],
  });

  final List<MapNode> nodes;

  /// The user's own location, drawn as the blue "YOU" marker and used as the
  /// origin of the connection arc. Null hides it and the arc.
  final LonLat? home;

  final Object? selectedId;
  final ValueChanged<Object>? onSelect;

  /// Fired in addition to [onSelect] when an already-selected node is tapped,
  /// which the picker uses as "connect".
  final ValueChanged<Object>? onNodeTap;

  final ArcState arc;
  final bool showLabels;
  final bool interactive;
  final bool showZoomControls;
  final bool showTooltip;

  /// Crops to a region instead of fitting the whole world.
  final LonLat? focus;
  final double zoomExtra;

  /// Fill the box and crop, rather than letterbox the whole world.
  final bool cover;

  /// How much of the world's width may be cropped so the map fills its pane
  /// instead of sitting in it as a strip. 0 letterboxes the whole world.
  final double maxCrop;

  final EdgeInsets padding;

  /// Points the initial view must contain — normally the user plus every
  /// location they have.
  ///
  /// When set, this replaces [cover]/[focus]/[zoomExtra] as the way the phone
  /// map is framed. Those three derive the scale from the viewport's aspect
  /// ratio, so the same account framed the world differently on every handset;
  /// framing the data instead makes the result depend on the account alone.
  /// See [NaturalEarth.fitPoints].
  final List<LonLat> fitPoints;

  /// Eases the viewport so home and the selected node are both in frame.
  final bool flyToSelection;

  @override
  State<MapCanvas> createState() => _MapCanvasState();
}

class _MapCanvasState extends State<MapCanvas> with TickerProviderStateMixin {
  /// One clock for every looping animation. 72 s divides evenly by the ping
  /// (3 s), packet (2.4 s) and spin (9 s) periods, so nothing jumps when it
  /// wraps.
  static const _clockSeconds = 72;

  late final AnimationController _clock;
  late final AnimationController _intro;
  late final AnimationController _arc;

  /// Viewport transform applied on top of the fitted projection.
  double _k = 1;
  Offset _pan = Offset.zero;

  // Gesture bookkeeping.
  double _startK = 1;
  Offset _startPan = Offset.zero;
  Offset _startFocal = Offset.zero;

  AnimationController? _fly;
  Object? _hoverId;
  Size _size = Size.zero;
  NaturalEarth? _base;

  static const _minK = 1.0;
  static const _maxK = 7.0;

  @override
  void initState() {
    super.initState();
    _clock = AnimationController(
      vsync: this,
      duration: const Duration(seconds: _clockSeconds),
    )..repeat();
    _intro = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    )..forward();
    _arc = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
    if (widget.arc != ArcState.none) _arc.forward();
  }

  @override
  void didUpdateWidget(covariant MapCanvas old) {
    super.didUpdateWidget(old);
    if (old.maxCrop != widget.maxCrop ||
        old.cover != widget.cover ||
        old.zoomExtra != widget.zoomExtra ||
        old.focus != widget.focus ||
        old.padding != widget.padding ||
        !listEquals(old.fitPoints, widget.fitPoints)) {
      _base = null;
    }
    final changed = old.selectedId != widget.selectedId;
    if (changed || old.arc != widget.arc) {
      if (widget.arc == ArcState.none) {
        _arc.value = 0;
      } else {
        _arc.forward(from: 0);
      }
    }
    if (changed && widget.flyToSelection) _flyToSelection();
  }

  @override
  void dispose() {
    _fly?.dispose();
    _arc.dispose();
    _intro.dispose();
    _clock.dispose();
    super.dispose();
  }

  bool get _reducedMotion =>
      MediaQuery.maybeDisableAnimationsOf(context) ?? false;

  NaturalEarth get _projection => _base ??= widget.fitPoints.isEmpty
      ? NaturalEarth.fit(
          _size,
          padding: widget.padding,
          extra: widget.zoomExtra,
          focus: widget.focus,
          cover: widget.cover,
          maxCrop: widget.maxCrop,
        )
      : NaturalEarth.fitPoints(
          _size,
          widget.fitPoints,
          padding: widget.padding,
        );

  Offset _toScreen(LonLat p) => _projection.projectPoint(p) * _k + _pan;

  // ── Viewport ───────────────────────────────────────────────────────────────

  /// Keeps the map covering the viewport, so panning can never reveal a void.
  ///
  /// Clamped against the *drawn world*, not the box: a `cover` fit already
  /// overflows the viewport at k = 1, and clamping to `size * (k - 1)` pinned
  /// the phone map in place even though there was map either side of it. When
  /// an axis really is smaller than the viewport the map is centred on it
  /// instead, so it can never drift into black space.
  Offset _clampPan(Offset pan, double k) {
    if (_size.isEmpty) return pan;
    final world = _projection.screenBounds;

    // The region the map is meant to fill. With a bottom padding — the phone
    // picker fits the world into the band above its sheet — that is *not* the
    // whole box, and clamping against the whole box was the bug: the world is
    // shorter than the viewport, so the "centre it" branch below yanked the
    // map down into the middle of the screen the instant it was touched,
    // leaving a gap along the top.
    final region = Rect.fromLTRB(
      widget.padding.left,
      widget.padding.top,
      _size.width - widget.padding.right,
      _size.height - widget.padding.bottom,
    );

    return clampPanToRegion(pan: pan, k: k, world: world, region: region);
  }

  void _setView(double k, Offset pan) {
    final nk = k.clamp(_minK, _maxK);
    setState(() {
      _k = nk;
      _pan = _clampPan(pan, nk);
    });
  }

  void _zoomBy(double factor, [Offset? about]) {
    final anchor = about ?? Offset(_size.width / 2, _size.height / 2);
    final nk = (_k * factor).clamp(_minK, _maxK);
    if (nk == _k) return;
    // Hold the anchor point still: the scene point under it must not move.
    final scene = (anchor - _pan) / _k;
    _setView(nk, anchor - scene * nk);
  }

  void _resetView() {
    _fly?.stop();
    _animateTo(1, Offset.zero);
  }

  void _animateTo(double k, Offset pan) {
    _fly?.dispose();
    final fromK = _k, fromPan = _pan;
    final toPan = _clampPan(pan, k);
    if (_reducedMotion) {
      _setView(k, toPan);
      _fly = null;
      return;
    }
    final c = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    );
    final curve = CurvedAnimation(parent: c, curve: Curves.easeInOutCubic);
    curve.addListener(() {
      final t = curve.value;
      setState(() {
        _k = fromK + (k - fromK) * t;
        _pan = Offset.lerp(fromPan, toPan, t)!;
      });
    });
    c.forward().whenComplete(c.dispose);
    _fly = c;
  }

  void _flyToSelection() {
    final home = widget.home;
    final node = _selected;
    if (home == null || node == null || _size.isEmpty) return;
    final base = _projection;
    final a = base.projectPoint(home);
    final b = base.projectPoint(node.coords);
    final span = math.max((a.dx - b.dx).abs(), (a.dy - b.dy).abs());
    final k = span <= 1
        ? 2.4
        : (math.min(_size.width, _size.height) * 0.62 / span)
            .clamp(_minK, 2.6);
    final centre = Offset((a.dx + b.dx) / 2, (a.dy + b.dy) / 2);
    _animateTo(
      k.toDouble(),
      Offset(_size.width / 2, _size.height / 2) - centre * k.toDouble(),
    );
  }

  MapNode? get _selected {
    for (final n in widget.nodes) {
      if (n.id == widget.selectedId) return n;
    }
    return null;
  }

  // ── Hit testing ────────────────────────────────────────────────────────────

  MapNode? _nodeAt(Offset local) {
    MapNode? best;
    var bestD = 18.0;
    for (final n in widget.nodes) {
      if (n.dimmed) continue;
      final d = (_toScreen(n.coords) - local).distance;
      if (d < bestD) {
        bestD = d;
        best = n;
      }
    }
    return best;
  }

  void _handleTap(Offset local) {
    final n = _nodeAt(local);
    if (n == null) return;
    if (n.id == widget.selectedId) {
      widget.onNodeTap?.call(n.id);
    } else {
      widget.onSelect?.call(n.id);
    }
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        final size = Size(box.maxWidth, box.maxHeight);
        if (size != _size) {
          _size = size;
          _base = null;
        }

        Widget canvas = RepaintBoundary(
          child: AnimatedBuilder(
            animation: Listenable.merge([_clock, _intro, _arc]),
            builder: (context, _) => CustomPaint(
              size: Size.infinite,
              painter: _MapPainter(
                projection: _projection,
                k: _k,
                pan: _pan,
                nodes: widget.nodes,
                home: widget.home,
                selectedId: widget.selectedId,
                hoverId: _hoverId,
                arcState: widget.arc,
                arcProgress: _arc.value,
                showLabels: widget.showLabels,
                clockMs: _clock.value * _clockSeconds * 1000,
                intro: _intro.value,
                reducedMotion: _reducedMotion,
              ),
            ),
          ),
        );

        canvas = MouseRegion(
          onHover: widget.showTooltip
              ? (e) {
                  final n = _nodeAt(e.localPosition);
                  if (n?.id != _hoverId) setState(() => _hoverId = n?.id);
                }
              : null,
          onExit: (_) {
            if (_hoverId != null) setState(() => _hoverId = null);
          },
          cursor: _hoverId != null
              ? SystemMouseCursors.click
              : (widget.interactive
                  ? SystemMouseCursors.grab
                  : MouseCursor.defer),
          child: canvas,
        );

        if (widget.interactive) {
          canvas = Listener(
            onPointerSignal: (e) {
              if (e is PointerScrollEvent) {
                _zoomBy(e.scrollDelta.dy < 0 ? 1.18 : 1 / 1.18,
                    e.localPosition);
              }
            },
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapUp: (d) => _handleTap(d.localPosition),
              onScaleStart: (d) {
                _fly?.stop();
                _startK = _k;
                _startPan = _pan;
                _startFocal = d.localFocalPoint;
              },
              onScaleUpdate: (d) {
                final nk = (_startK * d.scale).clamp(_minK, _maxK);
                // Scale about the gesture's focal point, then apply the drag.
                final scene = (_startFocal - _startPan) / _startK;
                _setView(nk, d.localFocalPoint - scene * nk);
              },
              child: canvas,
            ),
          );
        } else {
          canvas = GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapUp: (d) => _handleTap(d.localPosition),
            child: canvas,
          );
        }

        final hovered = _hoverId == null
            ? null
            : widget.nodes.where((n) => n.id == _hoverId).firstOrNull;

        return ClipRect(
          child: Stack(
            children: [
              Positioned.fill(child: canvas),
              if (hovered != null && widget.showTooltip)
                _Tooltip(node: hovered, at: _toScreen(hovered.coords)),
              if (widget.showZoomControls && widget.interactive)
                Positioned(
                  top: 14,
                  right: 14,
                  child: _ZoomStack(
                    onIn: () => _zoomBy(1.5),
                    onOut: () => _zoomBy(1 / 1.5),
                    onReset: _resetView,
                    canOut: _k > _minK + 0.01,
                    canIn: _k < _maxK - 0.01,
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

// ── Painter ──────────────────────────────────────────────────────────────────

class _MapPainter extends CustomPainter {
  _MapPainter({
    required this.projection,
    required this.k,
    required this.pan,
    required this.nodes,
    required this.home,
    required this.selectedId,
    required this.hoverId,
    required this.arcState,
    required this.arcProgress,
    required this.showLabels,
    required this.clockMs,
    required this.intro,
    required this.reducedMotion,
  });

  final NaturalEarth projection;
  final double k;
  final Offset pan;
  final List<MapNode> nodes;
  final LonLat? home;
  final Object? selectedId;
  final Object? hoverId;
  final ArcState arcState;
  final double arcProgress;
  final bool showLabels;
  final double clockMs;
  final double intro;
  final bool reducedMotion;

  Offset _p(LonLat c) => projection.projectPoint(c) * k + pan;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.clipRect(Offset.zero & size);

    // The stage paints its own backdrop so it reads the same wherever it is
    // embedded, with the mockup's soft glow behind the northern hemisphere.
    canvas.drawRect(Offset.zero & size, Paint()..color = VeilColors.bg);
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(0, -0.64),
          radius: 0.9,
          colors: [
            VeilColors.tint(0.028),
            VeilColors.tint(0),
          ],
        ).createShader(Offset.zero & size),
    );

    // The world is fitted to the landmasses, so the equator is wider than the
    // frame. Clipping the graticule and land to the globe keeps low-latitude
    // meridians from running off as straight lines across the whole canvas.
    final sphere = Path();
    var first = true;
    for (final c in sphereOutline()) {
      final o = _p(c);
      first ? sphere.moveTo(o.dx, o.dy) : sphere.lineTo(o.dx, o.dy);
      first = false;
    }
    sphere.close();

    canvas.save();
    canvas.clipPath(sphere);
    _paintGraticule(canvas);
    _paintLand(canvas);
    canvas.restore();

    canvas.drawPath(
      sphere,
      Paint()
        ..color = VeilColors.tint(0.07)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.8,
    );

    _paintArc(canvas);
    _paintHome(canvas);
    _paintNodes(canvas);
    if (showLabels) _paintLabels(canvas);
  }

  void _paintGraticule(Canvas canvas) {
    final grid = Paint()
      ..color = VeilColors.tint(0.035)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.5;
    for (final line in graticule()) {
      final path = Path();
      var f = true;
      for (final c in line) {
        final o = _p(c);
        f ? path.moveTo(o.dx, o.dy) : path.lineTo(o.dx, o.dy);
        f = false;
      }
      canvas.drawPath(path, grid);
    }
  }

  void _paintLand(Canvas canvas) {
    final rings = worldRings();
    final fill = Paint()..color = VeilColors.land;
    final stroke = Paint()
      ..color = VeilColors.landStroke
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.5;

    // Staggered fade-in on first paint, in the same 22-ring cadence as the
    // mockup's `animation-delay`.
    for (var i = 0; i < rings.length; i++) {
      final delay = reducedMotion ? 0.0 : (i % 22) * 22 / 800;
      final t = ((intro - delay) / (1 - delay).clamp(0.01, 1)).clamp(0.0, 1.0);
      if (t <= 0) continue;

      final path = Path();
      var f = true;
      for (final c in rings[i]) {
        final o = _p(c);
        f ? path.moveTo(o.dx, o.dy) : path.lineTo(o.dx, o.dy);
        f = false;
      }
      path.close();

      if (t >= 1) {
        canvas.drawPath(path, fill);
        canvas.drawPath(path, stroke);
      } else {
        canvas.drawPath(path, Paint()..color = fill.color.withValues(alpha: t));
        canvas.drawPath(
          path,
          Paint()
            ..color = stroke.color.withValues(alpha: t)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 0.5,
        );
      }
    }
  }

  void _paintArc(Canvas canvas) {
    final h = home;
    final sel = _selectedNode;
    if (h == null || sel == null || arcState == ArcState.none) return;

    final pts = greatCircle(h, sel.coords).map(_p).toList();
    if (pts.length < 2) return;

    final path = Path()..moveTo(pts.first.dx, pts.first.dy);
    for (final p in pts.skip(1)) {
      path.lineTo(p.dx, p.dy);
    }

    final metric = path.computeMetrics().first;
    final drawn = reducedMotion ? 1.0 : arcProgress;
    final visible = metric.extractPath(0, metric.length * drawn);

    final connecting = arcState == ArcState.connecting;
    final pulse = connecting && !reducedMotion
        ? 0.55 + 0.45 * (0.5 + 0.5 * math.sin(clockMs / 1000 * math.pi))
        : 1.0;

    canvas.drawPath(
      visible,
      Paint()
        ..shader = LinearGradient(
          colors: connecting
              ? [
                  VeilColors.warn.withValues(alpha: 0.25 * pulse),
                  VeilColors.warn.withValues(alpha: pulse),
                ]
              : [
                  VeilColors.info.withValues(alpha: 0.25),
                  VeilColors.accent,
                  VeilColors.accentHi,
                ],
          stops: connecting ? null : const [0.0, 0.45, 1.0],
        ).createShader(Rect.fromPoints(pts.first, pts.last))
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );

    // Packet dot: only once the line has finished drawing, on a 2.4 s loop.
    if (reducedMotion || drawn < 1 || arcState != ArcState.connected) return;
    final phase = (clockMs % 2400) / 2400;
    if (phase > 0.625) return; // 1.5 s of travel, then a pause
    final t = Curves.easeInOut.transform((phase / 0.625).clamp(0.0, 1.0));
    final tan = metric.getTangentForOffset(metric.length * t);
    if (tan == null) return;
    canvas.drawCircle(
      tan.position,
      5,
      Paint()
        ..color = VeilColors.accent.withValues(alpha: 0.35)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4),
    );
    canvas.drawCircle(tan.position, 2.6, Paint()..color = VeilColors.accentHi);
  }

  MapNode? get _selectedNode {
    for (final n in nodes) {
      if (n.id == selectedId) return n;
    }
    return null;
  }

  void _paintHome(Canvas canvas) {
    final h = home;
    if (h == null) return;
    final o = _p(h);

    if (!reducedMotion) {
      final t = (clockMs % 3400) / 3400;
      final r = 5 * (0.5 + 2.9 * Curves.easeOut.transform(t));
      final a = (0.65 * (1 - t / 0.7)).clamp(0.0, 1.0);
      if (a > 0) {
        canvas.drawCircle(
          o,
          r,
          Paint()
            ..color = VeilColors.info.withValues(alpha: a)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1,
        );
      }
    }
    canvas.drawCircle(o, 3.4, Paint()..color = VeilColors.info);
    canvas.drawCircle(
      o,
      3.4,
      Paint()
        ..color = VeilColors.bg
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2,
    );
    if (showLabels) {
      _text(canvas, 'YOU', o.translate(0, -13), VeilColors.info, 9.5);
    }
  }

  void _paintNodes(Canvas canvas) {
    for (var i = 0; i < nodes.length; i++) {
      final n = nodes[i];
      final o = _p(n.coords);
      final selected = n.id == selectedId;
      final hovered = n.id == hoverId;
      final alpha = n.dimmed ? 0.25 : 1.0;

      final colour = n.offline
          ? VeilColors.muted
          : n.busy
              ? VeilColors.warn
              : VeilColors.accentHi;
      final haloColour = n.offline
          ? VeilColors.muted
          : n.busy
              ? VeilColors.warn
              : VeilColors.accent;

      // Ping ring — phase-offset per node so they never pulse in unison.
      if (!reducedMotion && !selected && !n.offline && !n.dimmed) {
        final t = ((clockMs + i * 370) % 3000) / 3000;
        final r = 4 * (0.5 + 2.9 * Curves.easeOut.transform(t));
        final a = (0.65 * (1 - t / 0.7)).clamp(0.0, 1.0);
        if (a > 0) {
          canvas.drawCircle(
            o,
            r,
            Paint()
              ..color = haloColour.withValues(alpha: a * alpha)
              ..style = PaintingStyle.stroke
              ..strokeWidth = 1.1,
          );
        }
      }

      canvas.drawCircle(
        o,
        selected ? 12 : (hovered ? 9 : 7),
        Paint()
          ..color = haloColour
              .withValues(alpha: (selected ? 0.28 : (hovered ? 0.3 : 0.14)) * alpha),
      );

      if (selected) _paintSelectionRing(canvas, o, haloColour);

      canvas.drawCircle(
        o,
        selected ? 5 : 3.2,
        Paint()..color = colour.withValues(alpha: alpha),
      );
      canvas.drawCircle(
        o,
        selected ? 5 : 3.2,
        Paint()
          ..color = VeilColors.bg.withValues(alpha: alpha)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2,
      );
    }
  }

  /// Dashed ring, rotating once every 9 s.
  void _paintSelectionRing(Canvas canvas, Offset centre, Color colour) {
    const r = 16.0;
    final rot = reducedMotion ? 0.0 : (clockMs % 9000) / 9000 * 2 * math.pi;
    final paint = Paint()
      ..color = colour
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4;

    // 3-on / 5-off dashes, drawn as arcs.
    const dash = 3.0, gap = 5.0;
    final circumference = 2 * math.pi * r;
    final step = (dash + gap) / circumference * 2 * math.pi;
    final sweep = dash / circumference * 2 * math.pi;
    for (var a = 0.0; a < 2 * math.pi; a += step) {
      canvas.drawArc(
        Rect.fromCircle(center: centre, radius: r),
        a + rot,
        sweep,
        false,
        paint,
      );
    }
  }

  void _paintLabels(Canvas canvas) {
    for (final n in nodes) {
      if (n.dimmed || n.label.isEmpty) continue;
      final o = _p(n.coords);
      _text(
        canvas,
        n.label.toUpperCase(),
        o.translate(0, n.id == selectedId ? -20 : -15),
        n.id == selectedId ? VeilColors.accentHi : VeilColors.text2,
        9.5,
      );
    }
  }

  /// Outlined text, so labels stay readable over land and sea alike — the
  /// mockup gets this from SVG `paint-order: stroke`.
  void _text(Canvas canvas, String s, Offset at, Color colour, double size) {
    TextPainter builder(TextStyle style) => TextPainter(
          text: TextSpan(text: s, style: style),
          textDirection: TextDirection.ltr,
        )..layout();

    final outline = builder(VeilText.mono(size: size, weight: 600).copyWith(
      foreground: Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..strokeJoin = StrokeJoin.round
        ..color = VeilColors.bg,
    ));
    final fill = builder(VeilText.mono(size: size, weight: 600, color: colour));

    final origin = Offset(at.dx - fill.width / 2, at.dy - fill.height);
    outline.paint(canvas, origin);
    fill.paint(canvas, origin);
  }

  @override
  bool shouldRepaint(_MapPainter old) => true;
}

// ── Chrome ───────────────────────────────────────────────────────────────────

class _Tooltip extends StatelessWidget {
  const _Tooltip({required this.node, required this.at});

  final MapNode node;
  final Offset at;

  @override
  Widget build(BuildContext context) {
    final title = node.name.isEmpty ? node.label : node.name;
    final meta = <String>[
      if (node.label.isNotEmpty && node.label != title) node.label,
      if (node.ping != null && node.ping! >= 0) '${node.ping} ms',
      if (node.load > 0) '${node.load}% load',
      if (node.subtitle.isNotEmpty) node.subtitle,
    ].join('  ·  ');

    return Positioned(
      left: at.dx,
      top: at.dy,
      child: FractionalTranslation(
        translation: const Offset(-0.5, -1.2),
        child: IgnorePointer(
          child: Container(
            padding: const EdgeInsets.fromLTRB(11, 8, 11, 8),
            decoration: BoxDecoration(
              color: VeilColors.elev,
              borderRadius: BorderRadius.circular(9),
              border: Border.all(color: VeilColors.border),
              boxShadow: [
                BoxShadow(color: VeilColors.shadow(0.55), blurRadius: 34, offset: Offset(0, 14)),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  node.cc.isEmpty ? title : '$title · ${node.cc}',
                  style: VeilText.ui(size: 12.5, weight: 600),
                ),
                if (meta.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(meta,
                        style: VeilText.mono(size: 10.5, color: VeilColors.muted)),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ZoomStack extends StatelessWidget {
  const _ZoomStack({
    required this.onIn,
    required this.onOut,
    required this.onReset,
    required this.canIn,
    required this.canOut,
  });

  final VoidCallback onIn;
  final VoidCallback onOut;
  final VoidCallback onReset;
  final bool canIn;
  final bool canOut;

  @override
  Widget build(BuildContext context) {
    Widget btn(IconData icon, String tip, VoidCallback? tap, {bool divider = false}) =>
        Container(
          decoration: divider
              ? BoxDecoration(
                  border: Border(top: BorderSide(color: VeilColors.borderSoft)))
              : null,
          child: Tooltip(
            message: tip,
            child: InkWell(
              onTap: tap,
              child: SizedBox(
                width: 32,
                height: 31,
                child: Icon(icon,
                    size: 14,
                    color: tap == null ? VeilColors.muted : VeilColors.text2),
              ),
            ),
          ),
        );

    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: Container(
        decoration: BoxDecoration(
          color: VeilColors.surface.withValues(alpha: 0.82),
          border: Border.all(color: VeilColors.border),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            btn(Icons.add_rounded, 'Zoom in', canIn ? onIn : null),
            btn(Icons.remove_rounded, 'Zoom out', canOut ? onOut : null,
                divider: true),
            btn(Icons.refresh_rounded, 'Fit world', canOut ? onReset : null,
                divider: true),
          ],
        ),
      ),
    );
  }
}
