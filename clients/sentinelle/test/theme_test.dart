import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:veil_client/theme.dart';

/// Contrast ratio per WCAG 2.1, so the light palette is held to a standard
/// rather than to an opinion.
double _contrast(Color a, Color b) {
  double channel(double c) =>
      c <= 0.03928 ? c / 12.92 : math.pow((c + 0.055) / 1.055, 2.4).toDouble();

  double lum(Color c) =>
      0.2126 * channel(c.r) + 0.7152 * channel(c.g) + 0.0722 * channel(c.b);

  final la = lum(a);
  final lb = lum(b);
  final hi = math.max(la, lb);
  final lo = math.min(la, lb);
  return (hi + 0.05) / (lo + 0.05);
}

void main() {
  tearDown(() => VeilTheme.apply(Brightness.dark));

  group('theme mode', () {
    test('system follows the platform, the others do not', () {
      expect(VeilTheme.resolve(AppThemeMode.system, Brightness.light),
          Brightness.light);
      expect(VeilTheme.resolve(AppThemeMode.system, Brightness.dark),
          Brightness.dark);
      expect(VeilTheme.resolve(AppThemeMode.light, Brightness.dark),
          Brightness.light);
      expect(VeilTheme.resolve(AppThemeMode.dark, Brightness.light),
          Brightness.dark);
    });

    test('an unknown stored value falls back to following the system', () {
      expect(AppThemeMode.parse(null), AppThemeMode.system);
      expect(AppThemeMode.parse('sepia'), AppThemeMode.system);
      expect(AppThemeMode.parse('light'), AppThemeMode.light);
    });
  });

  group('palettes', () {
    test('the tokens actually change with the theme', () {
      VeilTheme.apply(Brightness.dark);
      final darkBg = VeilColors.bg;
      final darkText = VeilColors.text;
      VeilTheme.apply(Brightness.light);
      expect(VeilColors.bg, isNot(darkBg));
      expect(VeilColors.text, isNot(darkText));
    });

    test('the page inverts rather than merely shifting', () {
      VeilTheme.apply(Brightness.dark);
      expect(VeilColors.bg.computeLuminance(), lessThan(0.1));
      expect(VeilColors.text.computeLuminance(), greaterThan(0.7));
      VeilTheme.apply(Brightness.light);
      expect(VeilColors.bg.computeLuminance(), greaterThan(0.7));
      expect(VeilColors.text.computeLuminance(), lessThan(0.1));
    });

    test('body text is readable on every surface, in both themes', () {
      for (final b in Brightness.values) {
        VeilTheme.apply(b);
        for (final surface in [VeilColors.bg, VeilColors.surface, VeilColors.surface2]) {
          expect(_contrast(VeilColors.text, surface), greaterThan(7.0),
              reason: 'primary text on $surface in $b');
          expect(_contrast(VeilColors.text2, surface), greaterThan(4.5),
              reason: 'secondary text on $surface in $b');
        }
      }
    });

    test('the accent is readable as text, which is why light gets a darker one',
        () {
      for (final b in Brightness.values) {
        VeilTheme.apply(b);
        expect(_contrast(VeilColors.accent, VeilColors.surface),
            greaterThan(3.0),
            reason: 'accent on surface in $b');
        // Buttons fill with the accent and write on top of it.
        expect(_contrast(VeilColors.onAccent, VeilColors.accent),
            greaterThan(4.5),
            reason: 'onAccent over accent in $b');
      }
    });

    test('semantic colours stay distinguishable from body text', () {
      for (final b in Brightness.values) {
        VeilTheme.apply(b);
        for (final c in [VeilColors.danger, VeilColors.warn, VeilColors.upload]) {
          expect(_contrast(c, VeilColors.surface), greaterThan(3.0),
              reason: '$c on surface in $b');
        }
      }
    });

    test('the raised wash lifts a dark surface and darkens a light one', () {
      VeilTheme.apply(Brightness.dark);
      expect(VeilColors.tint(0.1).r, 1.0);

      // On light it darkens — but with a warm brown rather than a neutral
      // black, or the wash would pull the cream surfaces back towards grey.
      VeilTheme.apply(Brightness.light);
      final wash = VeilColors.tint(1.0);
      expect(_contrast(wash, VeilColors.surface), greaterThan(4.5),
          reason: 'the light wash has to darken what is under it');
      expect(wash.r, greaterThan(wash.b),
          reason: 'the light wash is warm, not neutral');
    });
  });

  group('material theme', () {
    test('is built for the brightness it is handed', () {
      VeilTheme.apply(Brightness.light);
      final light = buildVeilTheme(Brightness.light);
      expect(light.brightness, Brightness.light);
      expect(light.scaffoldBackgroundColor, VeilColors.bg);

      VeilTheme.apply(Brightness.dark);
      final dark = buildVeilTheme(Brightness.dark);
      expect(dark.brightness, Brightness.dark);
      expect(dark.scaffoldBackgroundColor, VeilColors.bg);
      expect(dark.scaffoldBackgroundColor,
          isNot(light.scaffoldBackgroundColor));
    });
  });
}
