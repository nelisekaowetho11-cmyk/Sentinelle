import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:veil_client/services/vpn/vpn_engine.dart';
import 'package:veil_client/theme.dart';
import 'package:veil_client/widgets/common.dart';
import 'package:veil_client/widgets/tunnel_orb.dart';

/// Renders every visual state of the shared widgets and fails on any
/// exception. This is what catches paint-time problems that asserts would
/// normally flag but release builds silently swallow — e.g. a gradient whose
/// `colors` and `stops` lists have different lengths.
void main() {
  Widget host(Widget child) => MaterialApp(
        theme: buildVeilTheme(),
        home: Scaffold(body: Center(child: child)),
      );

  group('TunnelOrb', () {
    for (final state in VpnState.values) {
      testWidgets('renders and paints in $state', (tester) async {
        await tester.pumpWidget(host(TunnelOrb(state: state, size: 180)));
        await tester.pump(const Duration(milliseconds: 300));
        expect(tester.takeException(), isNull);

        // Force a real paint pass — gradient length mismatches only blow up here.
        final orb = find.byType(TunnelOrb);
        expect(orb, findsOneWidget);
        await tester.pump(const Duration(milliseconds: 800));
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('tap fires the callback', (tester) async {
      var taps = 0;
      await tester.pumpWidget(host(TunnelOrb(
        state: VpnState.disconnected,
        size: 160,
        onTap: () => taps++,
      )));
      await tester.tap(find.byType(TunnelOrb));
      expect(taps, 1);
    });
  });

  group('shared widgets', () {
    testWidgets('status pill, chips and flags render', (tester) async {
      await tester.pumpWidget(host(Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          StatusPill(label: 'Connected', pulse: true),
          StatusPill(label: 'Disconnected', color: VeilColors.muted),
          ProtoChip(protocol: 'vless', label: 'VLESS · Reality'),
          ProtoChip(protocol: 'trojan', label: 'TROJAN'),
          FlagChip(country: 'DE'),
          FlagChip(country: '', fallback: 'reality-in'),
        ],
      )));
      await tester.pump(const Duration(milliseconds: 500));
      expect(tester.takeException(), isNull);
      expect(find.text('CONNECTED'), findsOneWidget);
    });

    testWidgets('speed tile handles empty, flat and spiky data', (tester) async {
      for (final data in [
        <double>[],
        List<double>.filled(40, 0),
        List<double>.generate(40, (i) => i.toDouble()),
      ]) {
        await tester.pumpWidget(host(SizedBox(
          width: 200,
          child: SpeedTile(
            label: 'Download',
            value: '48.2',
            unit: 'Mbps',
            icon: Icons.south_rounded,
            color: VeilColors.accent,
            spark: data,
          ),
        )));
        await tester.pump();
        expect(tester.takeException(), isNull);
      }
    });

    testWidgets('quota bar clamps out-of-range values', (tester) async {
      for (final pct in [-10.0, 0.0, 55.0, 99.9, 140.0]) {
        await tester.pumpWidget(host(SizedBox(width: 200, child: QuotaBar(pct: pct))));
        await tester.pump();
        expect(tester.takeException(), isNull);
      }
    });

    testWidgets('switch toggles', (tester) async {
      var on = false;
      await tester.pumpWidget(host(StatefulBuilder(
        builder: (_, setState) => VeilSwitch(
          value: on,
          onChanged: (v) => setState(() => on = v),
        ),
      )));
      await tester.tap(find.byType(VeilSwitch));
      await tester.pump(const Duration(milliseconds: 300));
      expect(on, isTrue);
      expect(tester.takeException(), isNull);
    });

    testWidgets('section and list rows render', (tester) async {
      await tester.pumpWidget(host(SizedBox(
        width: 320,
        child: VeilSection(
          title: 'Connection',
          children: [
            VeilListRow(
              label: 'Auto-connect',
              sub: 'Reconnect to the last server',
              icon: Icons.bolt_rounded,
              trailing: VeilSwitch(value: true, onChanged: (_) {}),
            ),
            const VeilListRow(label: 'No subtitle', showDivider: false),
          ],
        ),
      )));
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.text('CONNECTION'), findsOneWidget);
    });
  });
}
