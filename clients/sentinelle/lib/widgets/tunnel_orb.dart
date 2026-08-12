import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../services/vpn/vpn_engine.dart';
import '../theme.dart';

/// The big animated connection orb from the mockup: ripples, two counter-
/// rotating dashed orbits, a glossy sphere and a state glyph.
class TunnelOrb extends StatefulWidget {
  const TunnelOrb({
    super.key,
    required this.state,
    this.size = 220,
    this.onTap,
  });

  final VpnState state;
  final double size;
  final VoidCallback? onTap;

  @override
  State<TunnelOrb> createState() => _TunnelOrbState();
}

class _TunnelOrbState extends State<TunnelOrb> with TickerProviderStateMixin {
  // Built in initState — lazy `late final` tickers would be constructed inside
  // dispose() if the orb never got a build, which throws during unmount.
  late final AnimationController _orbit;
  late final AnimationController _orbitRev;
  late final AnimationController _ripple;
  late final AnimationController _glow;

  @override
  void initState() {
    super.initState();
    _orbit = AnimationController(
        vsync: this, duration: const Duration(seconds: 22))
      ..repeat();
    _orbitRev = AnimationController(
        vsync: this, duration: const Duration(seconds: 32))
      ..repeat();
    _ripple = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 2600))
      ..repeat();
    _glow = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 2400))
      ..repeat(reverse: true);
  }

  @override
  void dispose() {
    _orbit.dispose();
    _orbitRev.dispose();
    _ripple.dispose();
    _glow.dispose();
    super.dispose();
  }

  bool get _connected => widget.state == VpnState.connected;
  bool get _connecting =>
      widget.state == VpnState.connecting || widget.state == VpnState.disconnecting;

  Color get _ring {
    if (_connected) return VeilColors.accent;
    if (_connecting) return VeilColors.warn;
    if (widget.state == VpnState.error) return VeilColors.danger;
    return VeilColors.orbIdleRing;
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.size;
    final outer = s + 80;

    return Clickable(
      enabled: widget.onTap != null,
      child: GestureDetector(
      onTap: widget.onTap,
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        width: outer,
        height: outer,
        child: Stack(
          alignment: Alignment.center,
          children: [
            if (_connected)
              for (var i = 0; i < 3; i++)
                AnimatedBuilder(
                  animation: _ripple,
                  builder: (context, child) {
                    final t = (_ripple.value + i / 3) % 1.0;
                    final scale = 0.85 + 0.75 * t;
                    return Opacity(
                      opacity: (0.75 * (1 - t)).clamp(0.0, 1.0),
                      child: Transform.scale(
                        scale: scale,
                        child: Container(
                          width: s,
                          height: s,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: VeilColors.accent.withValues(alpha: 0.35),
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),

            // Dashed orbits
            AnimatedBuilder(
              animation: Listenable.merge([_orbit, _orbitRev]),
              builder: (context, child) => CustomPaint(
                size: Size(outer, outer),
                painter: _OrbitPainter(
                  color: _ring,
                  radiusInner: s / 2 + 12,
                  radiusOuter: s / 2 + 30,
                  angleInner: _connected ? _orbit.value * 2 * math.pi : 0,
                  angleOuter: _connected ? -_orbitRev.value * 2 * math.pi : 0,
                ),
              ),
            ),

            // The sphere
            AnimatedBuilder(
              animation: _glow,
              builder: (context, child) {
                final pulse = _connected ? _glow.value : 0.0;
                // colors and stops must stay the same length — a mismatch
                // throws in dart:ui at paint time (asserts are off in release).
                final (colors, stops) = _connected
                    ? (
                        [VeilColors.accent, VeilColors.accentLo, VeilColors.accentDeep],
                        const [0.0, 0.7, 1.0],
                      )
                    : _connecting
                        ? (
                            [VeilColors.warn, VeilColors.warnDeep],
                            const [0.0, 1.0],
                          )
                        : (
                            [VeilColors.orbIdleFrom, VeilColors.orbIdleTo],
                            const [0.0, 1.0],
                          );
                return Container(
                  width: s,
                  height: s,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: RadialGradient(
                      center: const Alignment(-0.3, -0.4),
                      radius: 0.95,
                      colors: colors,
                      stops: stops,
                    ),
                    boxShadow: [
                      if (_connected)
                        BoxShadow(
                          color: VeilColors.accent.withValues(alpha: 0.30 + 0.20 * pulse),
                          blurRadius: 70 + 25 * pulse,
                          spreadRadius: 2,
                        )
                      else if (_connecting)
                        BoxShadow(
                          color: VeilColors.warn.withValues(alpha: 0.35),
                          blurRadius: 60,
                        )
                      else
                        BoxShadow(color: VeilColors.shadow(0.40), blurRadius: 30),
                    ],
                  ),
                  child: child,
                );
              },
              child: Stack(
                alignment: Alignment.center,
                children: [
                  // Specular highlight
                  Positioned(
                    top: s * 0.08,
                    left: s * 0.20,
                    right: s * 0.20,
                    height: s * 0.30,
                    child: ClipOval(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(s),
                          color: VeilColors.tint(0.18),
                        ),
                      ),
                    ),
                  ),
                  _StateGlyph(state: widget.state, size: s * 0.32),
                ],
              ),
            ),
          ],
        ),
      ),
      ),
    );
  }
}

class _StateGlyph extends StatelessWidget {
  const _StateGlyph({required this.state, required this.size});
  final VpnState state;
  final double size;

  @override
  Widget build(BuildContext context) {
    final color = state == VpnState.connected
        ? VeilColors.onAccent
        : state == VpnState.connecting || state == VpnState.disconnecting
            ? VeilColors.onWarn
            : VeilColors.onIdle;

    final icon = switch (state) {
      VpnState.connected => Icons.verified_user_rounded,
      VpnState.connecting => Icons.shield_moon_rounded,
      VpnState.disconnecting => Icons.shield_moon_rounded,
      VpnState.error => Icons.gpp_bad_rounded,
      VpnState.disconnected => Icons.shield_outlined,
    };

    return Icon(icon, size: size, color: color);
  }
}

class _OrbitPainter extends CustomPainter {
  _OrbitPainter({
    required this.color,
    required this.radiusInner,
    required this.radiusOuter,
    required this.angleInner,
    required this.angleOuter,
  });

  final Color color;
  final double radiusInner;
  final double radiusOuter;
  final double angleInner;
  final double angleOuter;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    _dashedCircle(canvas, center, radiusInner, angleInner,
        color.withValues(alpha: 0.18), 2, 7);
    _dashedCircle(canvas, center, radiusOuter, angleOuter,
        color.withValues(alpha: 0.10), 1, 12);
  }

  void _dashedCircle(Canvas canvas, Offset c, double r, double rotation,
      Color color, double dash, double gap) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..strokeCap = StrokeCap.round;
    final circumference = 2 * math.pi * r;
    final step = (dash + gap) / r; // radians per dash+gap
    final count = (circumference / (dash + gap)).floor();
    for (var i = 0; i < count; i++) {
      final start = rotation + i * step;
      canvas.drawArc(
        Rect.fromCircle(center: c, radius: r),
        start,
        dash / r,
        false,
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_OrbitPainter old) =>
      old.angleInner != angleInner ||
      old.angleOuter != angleOuter ||
      old.color != color;
}
