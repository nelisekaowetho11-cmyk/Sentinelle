import 'dart:io';

import 'package:flutter/material.dart';

import '../services/vpn/desktop_engine.dart';
import '../services/vpn/vpn_engine.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'shell.dart' show mobileTabBarClearance;

class StatsScreen extends StatelessWidget {
  const StatsScreen({super.key, required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 900;
    final st = state.vpnStats;
    final down = formatSpeed(st.downloadSpeed);
    final up = formatSpeed(st.uploadSpeed);
    final server = state.activeServer ?? state.selectedServer;
    final p = state.profile;

    return SafeArea(
      bottom: false,
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
            16, 10, 16, wide ? 24 : mobileTabBarClearance(context)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text('Session statistics',
                      style: VeilText.display(size: 20, weight: 600)),
                ),
                IconButton(
                  tooltip: 'Refresh account',
                  onPressed: () => state.refresh(),
                  icon: const Icon(Icons.refresh_rounded, size: 19),
                  color: VeilColors.text2,
                ),
              ],
            ),
            const SizedBox(height: 12),

            // ── Live throughput ────────────────────────────────────────────
            VeilCard(
              radius: VeilRadius.xl,
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      StatusPill(
                        label: state.isConnected ? 'Live throughput' : 'Idle',
                        color: state.isConnected ? VeilColors.accent : VeilColors.muted,
                        pulse: state.isConnected,
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      _Metric(label: 'Down', value: down.value, unit: down.unit),
                      const SizedBox(width: 26),
                      _Metric(label: 'Up', value: up.value, unit: up.unit),
                    ],
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    height: 120,
                    child: Stack(
                      children: [
                        MiniSpark(
                            data: state.downHistory,
                            color: VeilColors.accent,
                            height: 120,
                            strokeWidth: 1.8),
                        MiniSpark(
                            data: state.upHistory,
                            color: VeilColors.upload,
                            height: 120,
                            strokeWidth: 1.4,
                            fill: false),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      _legend(VeilColors.accent, 'Download'),
                      const SizedBox(width: 16),
                      _legend(VeilColors.upload, 'Upload'),
                      const Spacer(),
                      Text('last 40 s',
                          style: VeilText.ui(size: 10.5, color: VeilColors.muted)),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),

            // ── Session ────────────────────────────────────────────────────
            //
            // A grid rather than a stack of rows. Ten label/value pairs down a
            // single column turned a wide window into a metre of whitespace
            // with a thin ribbon of text down the middle, and made you scroll
            // for facts that all fit on one screen.
            _GridSection(
              title: 'Session',
              tiles: [
                _Stat('Status', _statusText(state.vpnState),
                    color: state.isConnected
                        ? VeilColors.accent
                        : VeilColors.text2),
                _Stat('Connected to', server?.name ?? '—'),
                _Stat('Location', server?.displayLocation ?? '—'),
                _Stat('Protocol', server?.protoLabel ?? '—'),
                _Stat('Endpoint',
                    server == null ? '—' : '${server.address}:${server.port}',
                    mono: true),
                _Stat('Session', formatDuration(st.duration), mono: true),
                _Stat('Downloaded', formatBytes(st.downloadTotal), mono: true),
                _Stat('Uploaded', formatBytes(st.uploadTotal), mono: true),
                _Stat('Local SOCKS',
                    '127.0.0.1:${state.engineOptions.socksPort}',
                    mono: true),
                _Stat('Local HTTP', '127.0.0.1:${state.engineOptions.httpPort}',
                    mono: true),
              ],
            ),

            // ── Account ────────────────────────────────────────────────────
            if (p != null)
              _GridSection(
                title: 'Account',
                tiles: [
                  _Stat('Account', p.username, mono: true),
                  _Stat('Plan status', p.status),
                  _Stat(
                      'Data used',
                      p.unlimited
                          ? '${p.trafficUsedGb.toStringAsFixed(2)} GB (unlimited)'
                          : '${p.trafficUsedGb.toStringAsFixed(2)} / ${p.trafficLimitGb.toStringAsFixed(0)} GB',
                      mono: true),
                  _Stat('Expires', p.expires.isEmpty ? 'Never' : p.expires,
                      mono: true),
                  _Stat('Device limit',
                      p.ipLimit == 0 ? 'Unlimited' : '${p.ipLimit}',
                      mono: true),
                  _Stat(
                      'Speed limit',
                      p.speedLimitKbps == 0
                          ? 'Unlimited'
                          : '${(p.speedLimitKbps / 1000).toStringAsFixed(1)} Mbps',
                      mono: true),
                ],
              ),

            // ── Desktop core log ───────────────────────────────────────────
            if (!Platform.isAndroid && state.engine is DesktopVpnEngine) ...[
              const SizedBox(height: 12),
              _CoreLog(engine: state.engine as DesktopVpnEngine),
            ],
          ],
        ),
      ),
    );
  }

  static String _statusText(VpnState s) => switch (s) {
        VpnState.connected => 'Connected',
        VpnState.connecting => 'Connecting',
        VpnState.disconnecting => 'Disconnecting',
        VpnState.error => 'Error',
        VpnState.disconnected => 'Disconnected',
      };

  static Widget _legend(Color c, String label) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(width: 8, height: 8, decoration: BoxDecoration(color: c, shape: BoxShape.circle)),
          const SizedBox(width: 6),
          Text(label, style: VeilText.ui(size: 11, color: VeilColors.muted)),
        ],
      );

}

/// One label/value pair in the stats grid.
class _Stat {
  const _Stat(this.label, this.value, {this.mono = false, this.color});

  final String label;
  final String value;
  final bool mono;
  final Color? color;
}

/// A captioned block of [_Stat] tiles, flowed into as many columns as the
/// window can carry.
///
/// Tiles rather than table rows: every value here is short, so a full-width
/// row spends all of its space on the gap between the label and the number.
class _GridSection extends StatelessWidget {
  const _GridSection({required this.title, required this.tiles});

  final String title;
  final List<_Stat> tiles;

  /// A tile needs roughly this much width before its value starts eliding.
  static const _minTileWidth = 210.0;
  static const _gap = 10.0;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 2, 4, 8),
            child: Text(title.toUpperCase(), style: VeilText.label()),
          ),
          LayoutBuilder(
            builder: (context, box) {
              final columns =
                  (box.maxWidth / _minTileWidth).floor().clamp(1, 5);
              final width =
                  (box.maxWidth - _gap * (columns - 1)) / columns;
              return Wrap(
                spacing: _gap,
                runSpacing: _gap,
                children: [
                  for (final t in tiles)
                    SizedBox(width: width, child: _StatTile(stat: t)),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

class _StatTile extends StatelessWidget {
  const _StatTile({required this.stat});

  final _Stat stat;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.fromLTRB(13, 11, 13, 12),
        decoration: BoxDecoration(
          color: VeilColors.surface,
          borderRadius: BorderRadius.circular(VeilRadius.md),
          border: Border.all(color: VeilColors.border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(stat.label.toUpperCase(),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: VeilText.label(size: 9.5, color: VeilColors.muted)),
            const SizedBox(height: 5),
            // Selectable: endpoints and local ports are things people copy
            // into another program, and a tooltip carries the full value when
            // the tile is too narrow for it.
            Tooltip(
              message: stat.value,
              child: Text(
                stat.value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: stat.mono
                    ? VeilText.mono(
                        size: 12.5, color: stat.color ?? VeilColors.text)
                    : VeilText.ui(
                        size: 13.5,
                        weight: 600,
                        color: stat.color ?? VeilColors.text),
              ),
            ),
          ],
        ),
      );
}

class _Metric extends StatelessWidget {
  const _Metric({required this.label, required this.value, required this.unit});
  final String label;
  final String value;
  final String unit;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label.toUpperCase(), style: VeilText.label(size: 10.5)),
          const SizedBox(height: 4),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(value, style: VeilText.display(size: 28, weight: 600)),
              const SizedBox(width: 4),
              Text(unit, style: VeilText.ui(size: 12, color: VeilColors.muted)),
            ],
          ),
        ],
      );
}

class _CoreLog extends StatefulWidget {
  const _CoreLog({required this.engine});
  final DesktopVpnEngine engine;

  @override
  State<_CoreLog> createState() => _CoreLogState();
}

class _CoreLogState extends State<_CoreLog> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final lines = widget.engine.log;
    return VeilCard(
      radius: VeilRadius.xl,
      padding: EdgeInsets.zero,
      child: Column(
        children: [
          VeilListRow(
            label: 'Core log',
            sub: '${lines.length} lines from the Xray process',
            icon: Icons.terminal_rounded,
            showDivider: _open,
            onTap: () => setState(() => _open = !_open),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  onPressed: () => setState(() {}),
                  icon: const Icon(Icons.refresh_rounded, size: 16),
                  color: VeilColors.muted,
                ),
                Icon(_open ? Icons.expand_less_rounded : Icons.expand_more_rounded,
                    size: 18, color: VeilColors.muted),
              ],
            ),
          ),
          if (_open)
            Container(
              width: double.infinity,
              constraints: const BoxConstraints(maxHeight: 220),
              padding: const EdgeInsets.all(12),
              color: VeilColors.bg,
              child: lines.isEmpty
                  ? Text('No output yet.',
                      style: VeilText.mono(size: 11, color: VeilColors.muted))
                  : SingleChildScrollView(
                      reverse: true,
                      child: SelectableText(
                        lines.join('\n'),
                        style: VeilText.mono(
                            size: 10.5, color: VeilColors.text2, height: 1.55),
                      ),
                    ),
            ),
        ],
      ),
    );
  }
}
