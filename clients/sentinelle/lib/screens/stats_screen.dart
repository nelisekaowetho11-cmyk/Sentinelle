import 'dart:io';

import 'package:flutter/material.dart';

import '../models/models.dart';
import '../models/sources.dart';
import '../services/subscription_service.dart';
import '../services/vpn/desktop_engine.dart';
import '../services/vpn/vpn_engine.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'shell.dart' show mobileTabBarClearance;

class StatsScreen extends StatefulWidget {
  const StatsScreen({super.key, required this.state});
  final AppState state;

  @override
  State<StatsScreen> createState() => _StatsScreenState();
}

class _StatsScreenState extends State<StatsScreen> {
  /// Which account's figures are on screen. Null until the user picks one, at
  /// which point the first source is showing.
  String? _sourceId;

  AppState get state => widget.state;

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 900;
    final st = state.vpnStats;
    final down = formatSpeed(st.downloadSpeed);
    final up = formatSpeed(st.uploadSpeed);
    final server = state.activeServer ?? state.selectedServer;

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

            // ── Accounts ───────────────────────────────────────────────────
            ..._accountSection(),

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

  // ── Accounts ───────────────────────────────────────────────────────────────

  /// One button per account, and the figures for whichever is selected.
  ///
  /// The screen used to show a single account: whichever one happened to be
  /// primary, with no hint that the others existed. Anyone signed into two
  /// panels — which the app has supported since sources landed — could see the
  /// quota of one of them and had no way at all to reach the rest.
  ///
  /// Subscriptions and imported configs are listed alongside the accounts
  /// rather than in a section of their own. They are all "somewhere my
  /// locations come from" to the person using the app, and a subscription
  /// carries the same used/remaining figures an account does.
  List<Widget> _accountSection() {
    final sources = state.sources.sources;
    if (sources.isEmpty) return const [];

    // A source that was signed out from another screen must not leave the
    // panel below showing figures from a source that is gone.
    final selected = sources.firstWhere(
      (s) => s.id == _sourceId,
      orElse: () => sources.first,
    );

    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(4, 2, 4, 8),
        child: Row(
          children: [
            Text(sources.length == 1 ? 'ACCOUNT' : 'ACCOUNTS',
                style: VeilText.label()),
            const Spacer(),
            if (sources.length > 1)
              Text('${sources.length} sources',
                  style: VeilText.ui(size: 10.5, color: VeilColors.muted)),
          ],
        ),
      ),
      // One tab per account. Kept even for a single source? No — a row of one
      // button is furniture, and the heading above already names it.
      if (sources.length > 1) ...[
        _AccountTabs(
          sources: sources,
          selectedId: selected.id,
          servers: (id) => state.sources.serversOf(id).length,
          blocked: (id) => state.sources.blockedReasonOf(id) != null,
          onSelect: (id) => setState(() => _sourceId = id),
        ),
        const SizedBox(height: 10),
      ],
      _AccountPanel(
        source: selected,
        profile: state.sources.profileOf(selected.id),
        usage: state.sources.usageOf(selected.id),
        blockedReason: state.sources.blockedReasonOf(selected.id),
        locations: state.sources.serversOf(selected.id).length,
      ),
      const SizedBox(height: 12),
    ];
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

/// The row of account buttons.
///
/// A horizontal strip rather than a wrapping row: the labels are panel
/// hostnames and usernames, so a handful of accounts would otherwise push the
/// figures below them off the bottom of a phone screen.
class _AccountTabs extends StatelessWidget {
  const _AccountTabs({
    required this.sources,
    required this.selectedId,
    required this.servers,
    required this.blocked,
    required this.onSelect,
  });

  final List<LocationSource> sources;
  final String selectedId;
  final int Function(String sourceId) servers;
  final bool Function(String sourceId) blocked;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) => SizedBox(
        height: 44,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 2),
          itemCount: sources.length,
          separatorBuilder: (_, _) => const SizedBox(width: 8),
          itemBuilder: (context, i) {
            final s = sources[i];
            final active = s.id == selectedId;
            return _AccountTab(
              label: s.displayLabel,
              icon: switch (s.kind) {
                SourceKind.account => Icons.account_circle_rounded,
                SourceKind.subscription => Icons.cloud_sync_rounded,
                SourceKind.manual => Icons.content_paste_rounded,
              },
              count: servers(s.id),
              active: active,
              // A source in trouble is worth spotting without opening it: a
              // paused account and an unreachable subscription both look like
              // "my locations went away" from the outside.
              warn: blocked(s.id) || s.error != null || !s.enabled,
              onTap: () => onSelect(s.id),
            );
          },
        ),
      );
}

class _AccountTab extends StatelessWidget {
  const _AccountTab({
    required this.label,
    required this.icon,
    required this.count,
    required this.active,
    required this.warn,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final int count;
  final bool active;
  final bool warn;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colour = active ? VeilColors.accent : VeilColors.text2;
    return Material(
      color: active
          ? VeilColors.accent.withValues(alpha: 0.14)
          : VeilColors.surface,
      borderRadius: BorderRadius.circular(VeilRadius.pill),
      child: InkWell(
        borderRadius: BorderRadius.circular(VeilRadius.pill),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          constraints: const BoxConstraints(maxWidth: 240),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(VeilRadius.pill),
            border: Border.all(
              color: active ? VeilColors.accent.withValues(alpha: 0.5) : VeilColors.border,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 15, color: colour),
              const SizedBox(width: 7),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: VeilText.ui(
                    size: 12.5,
                    weight: active ? 600 : 500,
                    color: active ? VeilColors.text : VeilColors.text2,
                  ),
                ),
              ),
              if (warn) ...[
                const SizedBox(width: 6),
                Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: VeilColors.danger,
                  ),
                ),
              ] else if (count > 0) ...[
                const SizedBox(width: 7),
                Text('$count',
                    style: VeilText.mono(size: 10.5, color: VeilColors.muted)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Everything known about one account, subscription or import.
class _AccountPanel extends StatelessWidget {
  const _AccountPanel({
    required this.source,
    required this.profile,
    required this.usage,
    required this.blockedReason,
    required this.locations,
  });

  final LocationSource source;
  final Profile? profile;
  final SubscriptionUsage? usage;
  final String? blockedReason;
  final int locations;

  @override
  Widget build(BuildContext context) {
    final p = profile;
    final u = usage;

    final double? pct = p != null
        ? (p.unlimited ? null : p.trafficPct)
        : (u != null && !u.unlimited ? u.usedPct : null);

    return VeilCard(
      radius: VeilRadius.xl,
      padding: const EdgeInsets.fromLTRB(14, 13, 14, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(source.displayLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: VeilText.display(size: 15, weight: 600)),
                    const SizedBox(height: 2),
                    Text(
                      [
                        source.kind.label,
                        '$locations location${locations == 1 ? '' : 's'}',
                        if (!source.enabled) 'disabled',
                      ].join(' · '),
                      style: VeilText.ui(size: 11, color: VeilColors.muted),
                    ),
                  ],
                ),
              ),
              StatusPill(
                label: _health,
                color: _healthColour,
              ),
            ],
          ),
          if (pct != null) ...[
            const SizedBox(height: 12),
            QuotaBar(pct: pct, height: 4),
          ],
          if (blockedReason != null || source.error != null) ...[
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(11, 9, 11, 10),
              decoration: BoxDecoration(
                color: VeilColors.danger.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(VeilRadius.sm),
                border: Border.all(
                    color: VeilColors.danger.withValues(alpha: 0.35)),
              ),
              child: Text(blockedReason ?? source.error!,
                  style: VeilText.ui(size: 11.5, color: VeilColors.text)),
            ),
          ],
          const SizedBox(height: 12),
          _GridSection(title: 'Details', tiles: _tiles()),
        ],
      ),
    );
  }

  String get _health {
    if (source.error != null) return 'Error';
    if (blockedReason != null) return 'Blocked';
    if (!source.enabled) return 'Disabled';
    final p = profile;
    if (p != null && !p.canConnect) return 'Inactive';
    return 'Active';
  }

  Color get _healthColour => switch (_health) {
        'Active' => VeilColors.accent,
        'Disabled' => VeilColors.muted,
        _ => VeilColors.danger,
      };

  List<_Stat> _tiles() {
    final p = profile;
    final u = usage;

    if (p != null) {
      return [
        _Stat('Account', p.username, mono: true),
        _Stat('Panel', _host(source.baseUrl), mono: true),
        _Stat('Plan status', p.status),
        _Stat(
            'Data used',
            p.unlimited
                ? '${p.trafficUsedGb.toStringAsFixed(2)} GB (unlimited)'
                : '${p.trafficUsedGb.toStringAsFixed(2)} / '
                    '${p.trafficLimitGb.toStringAsFixed(0)} GB',
            mono: true),
        _Stat(
            'Remaining',
            p.unlimited
                ? 'Unlimited'
                : '${(p.trafficLeftGb ?? 0).toStringAsFixed(2)} GB',
            mono: true),
        _Stat('Expires', p.expires.isEmpty ? 'Never' : p.expires, mono: true),
        if (p.daysLeft != null)
          _Stat('Days left', '${p.daysLeft}', mono: true),
        _Stat(
            'Devices',
            p.ipLimit == 0
                ? (p.devicesInUse == null
                    ? 'Unlimited'
                    : '${p.devicesInUse} · unlimited')
                : '${p.devicesInUse ?? '?'} / ${p.ipLimit}',
            mono: true,
            color: p.atDeviceLimit ? VeilColors.danger : null),
        _Stat(
            'Speed limit',
            p.speedLimitKbps == 0
                ? 'Unlimited'
                : '${(p.speedLimitKbps / 1000).toStringAsFixed(1)} Mbps',
            mono: true),
        _Stat('Locations', '$locations', mono: true),
        _Stat('Updated', _ago(source.lastRefresh), mono: true),
      ];
    }

    if (u != null) {
      return [
        _Stat('Subscription', source.displayLabel),
        _Stat('Host', _host(source.url), mono: true),
        _Stat(
            'Data used',
            u.unlimited
                ? '${formatBytes(u.usedBytes)} (unlimited)'
                : '${formatBytes(u.usedBytes)} / ${formatBytes(u.totalBytes)}',
            mono: true),
        _Stat('Downloaded', formatBytes(u.downloadBytes), mono: true),
        _Stat('Uploaded', formatBytes(u.uploadBytes), mono: true),
        _Stat(
            'Expires',
            u.expiry == null
                ? 'Never'
                : u.expiry!.toIso8601String().split('T').first,
            mono: true),
        _Stat('Locations', '$locations', mono: true),
        _Stat('Updated', _ago(source.lastRefresh), mono: true),
      ];
    }

    // A subscription that has not answered yet, or pasted configs — which
    // genuinely have nothing behind them but the list itself.
    return [
      _Stat('Kind', source.kind.label),
      if (source.url.isNotEmpty) _Stat('Host', _host(source.url), mono: true),
      if (source.baseUrl.isNotEmpty)
        _Stat('Panel', _host(source.baseUrl), mono: true),
      _Stat('Locations', '$locations', mono: true),
      _Stat('Updated', _ago(source.lastRefresh), mono: true),
    ];
  }

  static String _host(String raw) {
    if (raw.isEmpty) return '—';
    final u = Uri.tryParse(raw);
    return (u == null || u.host.isEmpty) ? raw : u.host;
  }

  static String _ago(DateTime? t) {
    if (t == null) return 'never';
    final d = DateTime.now().difference(t);
    if (d.inSeconds < 90) return 'just now';
    if (d.inMinutes < 60) return '${d.inMinutes}m ago';
    if (d.inHours < 24) return '${d.inHours}h ago';
    return '${d.inDays}d ago';
  }
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
