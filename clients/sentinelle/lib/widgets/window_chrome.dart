import 'dart:io';

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../theme.dart';
import 'common.dart';

/// Frameless title bar: drag area, live status, and animated window buttons.
///
/// The OS chrome is switched off in `main()`, so these buttons are the only way
/// to move, minimise, maximise or close the window.
class VeilTitleBar extends StatefulWidget {
  const VeilTitleBar({
    super.key,
    required this.title,
    this.subtitle,
    this.accent = false,
  });

  final String title;
  final String? subtitle;

  /// Tints the status dot when the tunnel is up.
  final bool accent;

  static const height = 40.0;

  @override
  State<VeilTitleBar> createState() => _VeilTitleBarState();
}

class _VeilTitleBarState extends State<VeilTitleBar> with WindowListener {
  bool _maximised = false;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    _refresh();
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  Future<void> _refresh() async {
    final m = await windowManager.isMaximized();
    if (mounted && m != _maximised) setState(() => _maximised = m);
  }

  @override
  void onWindowMaximize() => _refresh();
  @override
  void onWindowUnmaximize() => _refresh();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: VeilTitleBar.height,
      child: DragToMoveArea(
        child: Container(
          decoration: BoxDecoration(
            color: VeilColors.surface,
            border: Border(bottom: BorderSide(color: VeilColors.borderSoft)),
          ),
          child: Row(
            children: [
              const SizedBox(width: 14),
              const VeilMark(size: 18),
              const SizedBox(width: 10),
              Text(widget.title,
                  style: VeilText.ui(size: 12.5, weight: 600, color: VeilColors.text2)),
              if (widget.subtitle != null) ...[
                const SizedBox(width: 8),
                AnimatedContainer(
                  duration: const Duration(milliseconds: 220),
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: widget.accent ? VeilColors.accent : VeilColors.muted,
                  ),
                ),
                const SizedBox(width: 6),
                Text(widget.subtitle!,
                    style: VeilText.ui(size: 11.5, color: VeilColors.muted)),
              ],
              const Expanded(child: SizedBox.expand()),
              _WindowButton(
                icon: _MinimiseIcon(),
                tooltip: 'Minimise',
                onTap: windowManager.minimize,
              ),
              _WindowButton(
                icon: _MaximiseIcon(restore: _maximised),
                tooltip: _maximised ? 'Restore' : 'Maximise',
                onTap: () async {
                  if (await windowManager.isMaximized()) {
                    await windowManager.unmaximize();
                  } else {
                    await windowManager.maximize();
                  }
                },
              ),
              _WindowButton(
                icon: _CloseIcon(),
                tooltip: 'Close',
                danger: true,
                onTap: windowManager.close,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _WindowButton extends StatefulWidget {
  const _WindowButton({
    required this.icon,
    required this.onTap,
    required this.tooltip,
    this.danger = false,
  });

  final Widget icon;
  final VoidCallback onTap;
  final String tooltip;
  final bool danger;

  @override
  State<_WindowButton> createState() => _WindowButtonState();
}

class _WindowButtonState extends State<_WindowButton> {
  bool _hover = false;
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final hoverColor =
        widget.danger ? VeilColors.danger : VeilColors.tint(0.10);
    return Tooltip(
      message: widget.tooltip,
      waitDuration: const Duration(milliseconds: 700),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() {
          _hover = false;
          _down = false;
        }),
        child: GestureDetector(
          onTapDown: (_) => setState(() => _down = true),
          onTapUp: (_) => setState(() => _down = false),
          onTapCancel: () => setState(() => _down = false),
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 140),
            curve: Curves.easeOut,
            width: 46,
            height: VeilTitleBar.height,
            color: _hover
                ? hoverColor.withValues(alpha: _down ? 0.85 : (widget.danger ? 1 : 0.10))
                : Colors.transparent,
            child: Center(
              child: AnimatedScale(
                duration: const Duration(milliseconds: 140),
                scale: _down ? 0.82 : 1.0,
                child: AnimatedOpacity(
                  duration: const Duration(milliseconds: 140),
                  opacity: _hover ? 1 : 0.72,
                  child: IconTheme(
                    data: IconThemeData(
                      color: (_hover && widget.danger)
                          ? Colors.white
                          : VeilColors.text2,
                      size: 11,
                    ),
                    child: widget.icon,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _MinimiseIcon extends StatelessWidget {
  @override
  Widget build(BuildContext context) => CustomPaint(
        size: const Size(11, 11),
        painter: _GlyphPainter(color: IconTheme.of(context).color!, glyph: _Glyph.minimise),
      );
}

class _MaximiseIcon extends StatelessWidget {
  const _MaximiseIcon({required this.restore});
  final bool restore;
  @override
  Widget build(BuildContext context) => AnimatedSwitcher(
        duration: const Duration(milliseconds: 180),
        transitionBuilder: (child, anim) => ScaleTransition(
          scale: anim,
          child: FadeTransition(opacity: anim, child: child),
        ),
        child: CustomPaint(
          key: ValueKey(restore),
          size: const Size(11, 11),
          painter: _GlyphPainter(
            color: IconTheme.of(context).color!,
            glyph: restore ? _Glyph.restore : _Glyph.maximise,
          ),
        ),
      );
}

class _CloseIcon extends StatelessWidget {
  @override
  Widget build(BuildContext context) => CustomPaint(
        size: const Size(11, 11),
        painter: _GlyphPainter(color: IconTheme.of(context).color!, glyph: _Glyph.close),
      );
}

enum _Glyph { minimise, maximise, restore, close }

class _GlyphPainter extends CustomPainter {
  _GlyphPainter({required this.color, required this.glyph});
  final Color color;
  final _Glyph glyph;

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = color
      ..strokeWidth = 1.1
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.square;
    final w = size.width, h = size.height;

    switch (glyph) {
      case _Glyph.minimise:
        canvas.drawLine(Offset(0, h / 2), Offset(w, h / 2), p);
        break;
      case _Glyph.maximise:
        canvas.drawRect(Rect.fromLTWH(0.5, 0.5, w - 1, h - 1), p);
        break;
      case _Glyph.restore:
        canvas.drawRect(Rect.fromLTWH(0.5, 2.5, w - 3, h - 3), p);
        final back = Path()
          ..moveTo(2.5, 2.0)
          ..lineTo(2.5, 0.5)
          ..lineTo(w - 0.5, 0.5)
          ..lineTo(w - 0.5, h - 3);
        canvas.drawPath(back, p);
        break;
      case _Glyph.close:
        canvas.drawLine(Offset.zero, Offset(w, h), p);
        canvas.drawLine(Offset(w, 0), Offset(0, h), p);
        break;
    }
  }

  @override
  bool shouldRepaint(_GlyphPainter old) =>
      old.color != color || old.glyph != glyph;
}

/// True when the app draws its own window chrome.
bool get usesCustomChrome =>
    Platform.isWindows || Platform.isLinux || Platform.isMacOS;
