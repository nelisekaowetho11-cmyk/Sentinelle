import 'dart:math' as math;

import 'package:country_flags/country_flags.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme.dart';

/// The app's primary action — connect, disconnect — with the mockup's
/// travelling sheen.
///
/// Shared rather than duplicated per screen so the busy state reads the same
/// everywhere: it used to dim to a flat green slab with the label swallowed,
/// which looked like a button that had stopped working.
class PrimaryActionButton extends StatefulWidget {
  const PrimaryActionButton({
    super.key,
    required this.label,
    required this.onTap,
    this.busy = false,
    this.danger = false,
    this.busyLabel = 'Connecting…',
    this.onCancel,
    this.height = 44,
  });

  final String label;
  final VoidCallback onTap;
  final bool busy;
  final bool danger;
  final String busyLabel;

  /// Makes the busy state abortable.
  ///
  /// Opt-in, because the two things this button does are not alike: a
  /// connection attempt can take half a minute against a server that is never
  /// going to answer, and the user must be able to give up on it — whereas a
  /// form submit that is already in flight has nothing useful to cancel.
  final VoidCallback? onCancel;

  final double height;

  @override
  State<PrimaryActionButton> createState() => _PrimaryActionButtonState();
}

class _PrimaryActionButtonState extends State<PrimaryActionButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _sheen = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2600),
  )..repeat();

  @override
  void dispose() {
    _sheen.dispose();
    super.dispose();
  }


  @override
  Widget build(BuildContext context) {
    final reduced = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final base = widget.danger ? VeilColors.danger : VeilColors.accent;
    final cancellable = widget.busy && widget.onCancel != null;
    final label = cancellable
        // Says what the tap will do, not what the app is doing — a button
        // reading "Connecting…" looks like a status line, and nobody presses a
        // status line to stop it.
        ? '${widget.busyLabel}  ·  Tap to cancel'
        : widget.busy
            ? widget.busyLabel
            : widget.label;

    return Clickable(
      enabled: !widget.busy || cancellable,
      child: GestureDetector(
      onTap: cancellable
          ? widget.onCancel
          : widget.busy
              ? null
              : widget.onTap,
      behavior: HitTestBehavior.opaque,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(11),
        child: Container(
          height: widget.height,
          decoration: BoxDecoration(
            // Full strength even while busy: a half-transparent slab was the
            // "button went blank and only shows green" report.
            color: base,
            borderRadius: BorderRadius.circular(11),
            boxShadow: [
              BoxShadow(color: base.withValues(alpha: 0.35), blurRadius: 22),
            ],
          ),
          child: Stack(
            alignment: Alignment.center,
            children: [
              if (!reduced && !widget.danger)
                AnimatedBuilder(
                  animation: _sheen,
                  builder: (context, _) => Positioned.fill(
                    child: FractionallySizedBox(
                      alignment: Alignment(-2.6 + 5.2 * _sheen.value, 0),
                      widthFactor: 0.38,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(colors: [
                            VeilColors.tint(0),
                            Colors.white
                                .withValues(alpha: widget.busy ? 0.5 : 0.32),
                            VeilColors.tint(0),
                          ]),
                        ),
                      ),
                    ),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (widget.busy)
                      SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: VeilColors.onAccent),
                      )
                    else
                      Icon(Icons.power_settings_new_rounded,
                          size: 16, color: VeilColors.onAccent),
                    if (cancellable) ...[
                      const SizedBox(width: 8),
                      Icon(Icons.close_rounded,
                          size: 15, color: VeilColors.onAccent),
                    ],
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: VeilText.ui(
                            size: 13.5, weight: 600, color: VeilColors.onAccent),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
      ),
    );
  }
}

/// Asks for a single value and returns it, or null if the user cancelled.
///
/// The dialog owns its [TextEditingController] and disposes it in its own
/// `dispose`. That is the whole point of this helper: every call site used to
/// create a controller, await `showDialog`, and dispose it on the next line —
/// but `showDialog`'s future completes when the route is *popped*, while the
/// exit transition is still running and the `TextField` is still mounted and
/// still listening. Disposing there threw
/// "A TextEditingController was used after being disposed", which unwound into
/// the `_dependents.isEmpty` assertion.
Future<String?> promptForText(
  BuildContext context, {
  required String title,
  String hint = '',
  String initial = '',
  String? helper,
  bool numeric = false,
  String saveLabel = 'Save',
}) =>
    showDialog<String>(
      context: context,
      builder: (context) => _TextPrompt(
        title: title,
        hint: hint,
        initial: initial,
        helper: helper,
        numeric: numeric,
        saveLabel: saveLabel,
      ),
    );

class _TextPrompt extends StatefulWidget {
  const _TextPrompt({
    required this.title,
    required this.hint,
    required this.initial,
    required this.helper,
    required this.numeric,
    required this.saveLabel,
  });

  final String title;
  final String hint;
  final String initial;
  final String? helper;
  final bool numeric;
  final String saveLabel;

  @override
  State<_TextPrompt> createState() => _TextPromptState();
}

class _TextPromptState extends State<_TextPrompt> {
  late final TextEditingController _ctrl =
      TextEditingController(text: widget.initial);

  @override
  void dispose() {
    // Runs when the route is genuinely gone, not when its future resolves.
    _ctrl.dispose();
    super.dispose();
  }

  void _save() => Navigator.pop(context, _ctrl.text);

  @override
  Widget build(BuildContext context) => AlertDialog(
        backgroundColor: VeilColors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(VeilRadius.lg),
          side: BorderSide(color: VeilColors.border),
        ),
        title: Text(widget.title,
            style: VeilText.display(size: 17, weight: 600)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _ctrl,
              autofocus: true,
              keyboardType:
                  widget.numeric ? TextInputType.number : TextInputType.text,
              inputFormatters: widget.numeric
                  ? [FilteringTextInputFormatter.digitsOnly]
                  : null,
              onSubmitted: (_) => _save(),
              style: VeilText.mono(size: 13),
              decoration: InputDecoration(
                  hintText: widget.hint.isEmpty ? null : widget.hint),
            ),
            if (widget.helper != null) ...[
              const SizedBox(height: 10),
              Text(widget.helper!,
                  style: VeilText.ui(
                      size: 11.5, color: VeilColors.muted, height: 1.5)),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            style: TextButton.styleFrom(foregroundColor: VeilColors.muted),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: _save,
            style: FilledButton.styleFrom(
                backgroundColor: VeilColors.accent,
                foregroundColor: VeilColors.onAccent),
            child: Text(widget.saveLabel),
          ),
        ],
      );
}

/// The Veil logotype mark.
class VeilMark extends StatelessWidget {
  const VeilMark({super.key, this.size = 28});
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(size * 0.3),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [VeilColors.accentHi, VeilColors.accentLo],
        ),
        boxShadow: [
          BoxShadow(
            color: VeilColors.accent.withValues(alpha: 0.35),
            blurRadius: size * 0.5,
          ),
        ],
      ),
      child: Center(
        child: Icon(Icons.shield_rounded,
            size: size * 0.58, color: VeilColors.onAccent),
      ),
    );
  }
}

/// Card surface used across every screen.
class VeilCard extends StatelessWidget {
  const VeilCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(14),
    this.radius = VeilRadius.lg,
    this.color,
    this.borderColor,
    this.margin,
    this.onTap,
  });

  final Widget child;
  final EdgeInsets padding;
  final double radius;
  final Color? color;
  final Color? borderColor;
  final EdgeInsets? margin;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final body = Container(
      padding: padding,
      decoration: BoxDecoration(
        color: color ?? VeilColors.surface,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: borderColor ?? VeilColors.border),
      ),
      child: child,
    );
    return Container(
      margin: margin,
      child: onTap == null
          ? body
          : Material(
              color: Colors.transparent,
              child: InkWell(
                borderRadius: BorderRadius.circular(radius),
                onTap: onTap,
                child: body,
              ),
            ),
    );
  }
}

/// Pill with an optional pulsing dot — "CONNECTED", "PRO", etc.
class StatusPill extends StatefulWidget {
  const StatusPill({
    super.key,
    required this.label,
    this.color,
    this.pulse = false,
    this.icon,
  });

  final String label;
  final Color? color;
  final bool pulse;
  final IconData? icon;

  @override
  State<StatusPill> createState() => _StatusPillState();
}

class _StatusPillState extends State<StatusPill>
    with SingleTickerProviderStateMixin {
  // Created in initState, not as a lazy `late final`: if the widget is
  // disposed before it ever builds, a lazy field would construct the ticker
  // *during* unmount and blow up with "deactivated widget's ancestor".
  late final AnimationController _c;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2200),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Resolved here rather than as a default: the accent is no longer a
    // compile-time constant, because it changes with the theme.
    final tone = widget.color ?? VeilColors.accent;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 6),
      decoration: BoxDecoration(
        color: tone.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(VeilRadius.pill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (widget.icon != null) ...[
            Icon(widget.icon, size: 12, color: tone),
            const SizedBox(width: 6),
          ] else ...[
            AnimatedBuilder(
              animation: _c,
              builder: (context, child) => Container(
                width: 6,
                height: 6,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: tone,
                  boxShadow: widget.pulse
                      ? [
                          BoxShadow(
                            color: tone.withValues(alpha: 0.5 * (1 - _c.value)),
                            blurRadius: 2,
                            spreadRadius: 4 * _c.value,
                          ),
                        ]
                      : null,
                ),
              ),
            ),
            const SizedBox(width: 7),
          ],
          Text(
            widget.label.toUpperCase(),
            style: VeilText.ui(
                size: 11, weight: 700, color: widget.color, letterSpacing: 1.0),
          ),
        ],
      ),
    );
  }
}

/// Protocol chip: "VLESS · Reality".
class ProtoChip extends StatelessWidget {
  const ProtoChip({super.key, required this.protocol, required this.label});
  final String protocol;
  final String label;

  @override
  Widget build(BuildContext context) {
    final c = VeilColors.protoColor(protocol);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(5),
      ),
      child: Text(label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: VeilText.mono(size: 10, weight: 500, color: c, letterSpacing: 0.4)),
    );
  }
}

/// The country's actual flag, drawn as a vector.
///
/// Emoji were the obvious answer and the wrong one: Windows has no flag glyphs
/// at all — Segoe UI Emoji renders a regional-indicator pair as a lettered
/// badge — so half the platforms this app ships on showed "DE" in a box where
/// the design called for a flag. These are SVGs, so they are sharp at any size
/// and identical everywhere.
///
/// [fallback] supplies a two-letter monogram for configs whose country nobody
/// has set, which is a normal state for a pasted link rather than an error.
class CountryFlagBox extends StatelessWidget {
  const CountryFlagBox({
    super.key,
    required this.country,
    this.fallback = '',
    this.width = 30,
    this.height = 22,
    this.selected = false,
    this.radius = 5,
  });

  final String country;
  final String fallback;
  final double width;
  final double height;

  /// Picks out the row the user is on, matching the old monogram box.
  final bool selected;
  final double radius;

  /// True when there is artwork for this code. Anything else — an empty
  /// country, or a code the flag set does not carry — falls back to letters
  /// rather than the package's white question mark.
  static bool hasFlag(String cc) {
    final c = cc.trim().toUpperCase();
    if (c.length != 2) return false;
    return FlagCode.fromCountryCode(c) != null;
  }

  @override
  Widget build(BuildContext context) {
    final border = Border.all(
        color: selected ? VeilColors.accent : VeilColors.borderSoft);

    if (hasFlag(country)) {
      return Container(
        width: width,
        height: height,
        decoration: BoxDecoration(
          border: border,
          borderRadius: BorderRadius.circular(radius),
          // The artwork is opaque, so the border has to sit on top of it —
          // otherwise the flag's own edge paints over the selection accent.
          color: VeilColors.elev,
        ),
        clipBehavior: Clip.antiAlias,
        child: FittedBox(
          fit: BoxFit.cover,
          child: CountryFlag.fromCountryCode(
            country.trim().toUpperCase(),
            theme: ImageTheme(width: width, height: height),
          ),
        ),
      );
    }

    final mono = (country.isNotEmpty ? country : fallback)
        .replaceAll(RegExp(r'[^A-Za-z0-9]'), '')
        .toUpperCase();
    return Container(
      width: width,
      height: height,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: VeilColors.elev,
        border: border,
        borderRadius: BorderRadius.circular(radius),
      ),
      child: Text(
        mono.isEmpty ? '?' : mono.substring(0, math.min(2, mono.length)),
        style: VeilText.mono(
          size: height <= 22 ? 10 : 11.5,
          weight: 600,
          color: selected ? VeilColors.accent : VeilColors.text2,
        ),
      ),
    );
  }
}

/// Circular country badge — the flag when we know the country, otherwise a
/// two-letter monogram so the layout never collapses.
class FlagChip extends StatelessWidget {
  const FlagChip({super.key, required this.country, this.fallback = '', this.size = 40});
  final String country;
  final String fallback;
  final double size;

  @override
  Widget build(BuildContext context) {
    final mono = (country.isNotEmpty ? country : fallback)
        .replaceAll(RegExp(r'[^A-Za-z0-9]'), '')
        .toUpperCase();
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: VeilColors.elev,
        border: Border.all(color: VeilColors.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: Center(
        child: CountryFlagBox.hasFlag(country)
            // Cropped to a disc rather than letterboxed: a 3:2 flag inside a
            // circle leaves two bites of empty surface top and bottom.
            ? SizedBox.expand(
                child: FittedBox(
                  fit: BoxFit.cover,
                  child: CountryFlag.fromCountryCode(
                    country.trim().toUpperCase(),
                    theme: ImageTheme(width: size * 1.5, height: size),
                  ),
                ),
              )
            : Text(
                mono.isEmpty ? '?' : mono.substring(0, math.min(2, mono.length)),
                style: VeilText.mono(
                    size: size * 0.32, weight: 600, color: VeilColors.text2),
              ),
      ),
    );
  }
}

/// Sparkline used under the speed tiles.
class MiniSpark extends StatelessWidget {
  const MiniSpark({
    super.key,
    required this.data,
    this.color,
    this.height = 24,
    this.strokeWidth = 1.4,
    this.fill = true,
  });

  final List<double> data;
  final Color? color;
  final double height;
  final double strokeWidth;
  final bool fill;

  @override
  Widget build(BuildContext context) => SizedBox(
        height: height,
        width: double.infinity,
        child: CustomPaint(
          painter: _SparkPainter(
              data: data,
              // The accent moves with the theme, so it cannot be a default.
              color: color ?? VeilColors.accent,
              strokeWidth: strokeWidth,
              fill: fill),
        ),
      );
}

class _SparkPainter extends CustomPainter {
  _SparkPainter({
    required this.data,
    required this.color,
    required this.strokeWidth,
    required this.fill,
  });

  final List<double> data;
  final Color color;
  final double strokeWidth;
  final bool fill;

  @override
  void paint(Canvas canvas, Size size) {
    if (data.length < 2 || size.width <= 0) return;
    final maxV = data.reduce(math.max);
    final scale = maxV <= 0 ? 1.0 : maxV;
    final dx = size.width / (data.length - 1);

    final path = Path();
    for (var i = 0; i < data.length; i++) {
      final x = i * dx;
      final y = size.height - (data[i] / scale) * (size.height - strokeWidth) - strokeWidth / 2;
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }

    if (fill) {
      final area = Path.from(path)
        ..lineTo(size.width, size.height)
        ..lineTo(0, size.height)
        ..close();
      canvas.drawPath(
        area,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [color.withValues(alpha: 0.25), color.withValues(alpha: 0.0)],
          ).createShader(Offset.zero & size),
      );
    }

    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..strokeJoin = StrokeJoin.round
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(_SparkPainter old) => true;
}

/// Download / upload tile with a live sparkline.
class SpeedTile extends StatelessWidget {
  const SpeedTile({
    super.key,
    required this.label,
    required this.value,
    required this.unit,
    required this.icon,
    required this.color,
    required this.spark,
    this.compact = false,
  });

  final String label;
  final String value;
  final String unit;
  final IconData icon;
  final Color? color;
  final List<double> spark;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return VeilCard(
      padding: EdgeInsets.symmetric(horizontal: compact ? 12 : 14, vertical: compact ? 10 : 12),
      radius: VeilRadius.md,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(icon, size: 13, color: color),
              const SizedBox(width: 7),
              Text(label,
                  style: VeilText.ui(
                      size: 11.5, weight: 500, color: VeilColors.muted)),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Flexible(
                child: Text(value,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: VeilText.display(size: compact ? 18 : 22, weight: 600)),
              ),
              const SizedBox(width: 4),
              Text(unit,
                  style: VeilText.ui(
                      size: 11, weight: 500, color: VeilColors.muted)),
            ],
          ),
          const SizedBox(height: 4),
          MiniSpark(data: spark, color: color, height: compact ? 18 : 24),
        ],
      ),
    );
  }
}

/// Row inside a settings / detail list.
class VeilListRow extends StatelessWidget {
  const VeilListRow({
    super.key,
    required this.label,
    this.sub,
    this.icon,
    this.trailing,
    this.onTap,
    this.showDivider = true,
  });

  final String label;
  final String? sub;
  final IconData? icon;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool showDivider;

  @override
  Widget build(BuildContext context) {
    final content = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        children: [
          if (icon != null) ...[
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: VeilColors.tint(0.05),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, size: 16, color: VeilColors.text2),
            ),
            const SizedBox(width: 12),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(label, style: VeilText.ui(size: 13.5, weight: 500)),
                if (sub != null && sub!.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(sub!,
                      style: VeilText.ui(size: 11.5, color: VeilColors.muted)),
                ],
              ],
            ),
          ),
          if (trailing != null) ...[const SizedBox(width: 10), trailing!],
        ],
      ),
    );

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        onTap == null
            ? content
            : Material(
                color: Colors.transparent,
                child: InkWell(onTap: onTap, child: content),
              ),
        if (showDivider)
          Divider(height: 1, thickness: 1, color: VeilColors.borderSoft),
      ],
    );
  }
}

/// Section wrapper with an uppercase caption.
class VeilSection extends StatelessWidget {
  const VeilSection({super.key, required this.title, required this.children});
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(6, 0, 6, 8),
            child: Text(title.toUpperCase(), style: VeilText.label()),
          ),
          Container(
            decoration: BoxDecoration(
              color: VeilColors.surface,
              borderRadius: BorderRadius.circular(VeilRadius.lg),
              border: Border.all(color: VeilColors.border),
            ),
            clipBehavior: Clip.antiAlias,
            child: Column(children: children),
          ),
          const SizedBox(height: 18),
        ],
      );
}

/// Lays [VeilSection] tiles out side by side as well as stacked.
///
/// A single column is the right shape on a phone and a waste of a desktop
/// window: Settings was a metre-long strip of cards with a hand's width of
/// empty space either side of it. Sections keep their own order but flow into
/// whichever column is currently shortest, so the two sides stay level instead
/// of one running far past the other.
class VeilSectionGrid extends StatelessWidget {
  const VeilSectionGrid({
    super.key,
    required this.sections,
    this.spacing = 16,
  });

  final List<VeilSection> sections;
  final double spacing;

  /// Two columns need room for two readable cards; three need a genuinely wide
  /// window. Below that a single column is not a compromise, it is correct.
  static const twoColumnWidth = 720.0;
  static const threeColumnWidth = 1180.0;

  static int columnsFor(double width) => width >= threeColumnWidth
      ? 3
      : width >= twoColumnWidth
          ? 2
          : 1;

  /// Rows plus the heading and the gap under the card. Only ever compared with
  /// another section's estimate, so it does not need to be in pixels.
  static int _weight(VeilSection s) => s.children.length + 2;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        final columns = columnsFor(box.maxWidth);
        if (columns == 1) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: sections,
          );
        }

        final buckets = List.generate(columns, (_) => <Widget>[]);
        final filled = List<int>.filled(columns, 0);
        for (final section in sections) {
          var shortest = 0;
          for (var i = 1; i < columns; i++) {
            if (filled[i] < filled[shortest]) shortest = i;
          }
          buckets[shortest].add(section);
          filled[shortest] += _weight(section);
        }

        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var i = 0; i < columns; i++) ...[
              if (i > 0) SizedBox(width: spacing),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: buckets[i],
                ),
              ),
            ],
          ],
        );
      },
    );
  }
}

class VeilSwitch extends StatelessWidget {
  const VeilSwitch({super.key, required this.value, required this.onChanged});
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => Clickable(
        child: GestureDetector(
        onTap: () => onChanged(!value),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          width: 40,
          height: 23,
          decoration: BoxDecoration(
            color: value ? VeilColors.accent : VeilColors.tint(0.10),
            borderRadius: BorderRadius.circular(VeilRadius.pill),
          ),
          child: AnimatedAlign(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOutCubic,
            alignment: value ? Alignment.centerRight : Alignment.centerLeft,
            child: Container(
              margin: const EdgeInsets.all(2.5),
              width: 18,
              height: 18,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: value ? VeilColors.onAccent : VeilColors.onIdle,
              ),
            ),
          ),
        ),
        ),
      );
}

/// Thin quota bar used on the profile card.
class QuotaBar extends StatelessWidget {
  const QuotaBar({super.key, required this.pct, this.height = 4});
  final double pct;
  final double height;

  @override
  Widget build(BuildContext context) {
    final p = (pct / 100).clamp(0.0, 1.0);
    final color = pct >= 90
        ? VeilColors.danger
        : pct >= 75
            ? VeilColors.warn
            : VeilColors.accent;
    return ClipRRect(
      borderRadius: BorderRadius.circular(height),
      child: LinearProgressIndicator(
        value: p,
        minHeight: height,
        backgroundColor: VeilColors.tint(0.07),
        valueColor: AlwaysStoppedAnimation(color),
      ),
    );
  }
}

void copyToClipboard(BuildContext context, String text, String message) {
  Clipboard.setData(ClipboardData(text: text));
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message), duration: const Duration(seconds: 2)));
}

void showVeilToast(BuildContext context, String message, {bool error = false}) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
      content: Row(
        children: [
          Icon(error ? Icons.error_outline_rounded : Icons.check_circle_outline_rounded,
              size: 16, color: error ? VeilColors.danger : VeilColors.accent),
          const SizedBox(width: 10),
          Expanded(child: Text(message)),
        ],
      ),
      duration: const Duration(seconds: 3),
    ));
}
