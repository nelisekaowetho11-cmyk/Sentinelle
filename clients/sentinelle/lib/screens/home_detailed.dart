import 'package:flutter/material.dart';

import '../models/models.dart';
import '../services/storage.dart';
import '../services/vpn/leak_guard.dart';
import '../services/vpn/vpn_engine.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/error_panel.dart';
import '../widgets/map/map_canvas.dart';
import '../widgets/map/server_nodes.dart';
import '../widgets/update_banner.dart';
import 'locations_screen.dart' show pingColour;

/// The detailed connect page: a live map with the route drawn on it, the
/// session summary across the top, and the security panel.
///
/// This is the default view. The simple orb page is still there for anyone who
/// wants it — see [Storage.detailedHome].
class DetailedHome extends StatelessWidget {
  const DetailedHome({
    super.key,
    required this.state,
    required this.onPickServer,
  });

  final AppState state;
  final VoidCallback onPickServer;

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 820;
    return wide ? _wide(context) : _narrow(context);
  }

  // ── Shared pieces ──────────────────────────────────────────────────────────

  ServerConfig? get _server => state.activeServer ?? state.selectedServer;

  Widget _map(BuildContext context, {required bool cover}) {
    final server = _server;
    final nodes = buildNodes(state.servers, pings: state.pings);
    final home = state.origin.country.isEmpty
        ? null
        : countryCentroid[state.origin.country];

    return MapCanvas(
      nodes: nodes,
      home: home,
      selectedId: server?.id,
      onSelect: (id) async {
        final s = state.servers.firstWhere((x) => x.id == id);
        await state.selectServer(s);
      },
      arc: server == null
          ? ArcState.none
          : state.isConnected
              ? ArcState.connected
              : state.isBusyConnecting
                  ? ArcState.connecting
                  : ArcState.selected,
      showLabels: !cover,
      interactive: !cover,
      showZoomControls: false,
      showTooltip: !cover,
      cover: cover,
      // Desktop panes are far squarer than the world, so a plain fit left the
      // map as a strip with empty bands above and below it. A capped crop
      // trades the far edges of the Pacific — still reachable by dragging —
      // for a map that uses the page.
      maxCrop: cover ? 0.0 : 0.24,
      // The phone frames the two ends of the route rather than covering the
      // viewport, so the same connection looks the same on every handset —
      // a cover fit takes its scale from the aspect ratio, which is not a
      // property of the account. See [NaturalEarth.fitPoints].
      fitPoints: cover
          ? [?home, ?(server == null ? null : serverCoords(server))]
          : const [],
    );
  }

  // ── Desktop / wide ─────────────────────────────────────────────────────────

  Widget _wide(BuildContext context) {
    return Stack(
      children: [
        // The map runs the full height of the stage and everything else floats
        // over it. Reserving a band for the status bar cost the map ~60px of
        // height for no reason — the bar is translucent and sits on top.
        Positioned.fill(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(VeilRadius.lg),
              child: _map(context, cover: false),
            ),
          ),
        ),
        Positioned(
          left: 16,
          right: 16,
          top: 8,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              _StatusBar(state: state, server: _server),
              if (UpdateBanner.visibleFor(state)) ...[
                const SizedBox(height: 8),
                UpdateBanner(state: state),
              ],
              // The reason lives here, under the status bar. Without it the
              // page said "ERROR" in a pill and nothing else — the message was
              // only ever rendered on the simple orb layout.
              if (state.connectionError != null) ...[
                const SizedBox(height: 8),
                ErrorPanel(state: state),
              ],
            ],
          ),
        ),
        Positioned(
          left: 30,
          bottom: 30,
          child: SizedBox(width: 330, child: _ServerCard(state: state, server: _server, onTap: onPickServer)),
        ),
        Positioned(
          right: 30,
          bottom: 30,
          child: SizedBox(width: 300, child: _SecurityPanel(state: state)),
        ),
      ],
    );
  }

  // ── Phone / narrow ─────────────────────────────────────────────────────────

  Widget _narrow(BuildContext context) {
    final connected = state.isConnected;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _StatusBar(state: state, server: _server, compact: true),
        if (UpdateBanner.visibleFor(state)) ...[
          const SizedBox(height: 8),
          UpdateBanner(state: state, compact: true),
        ],
        const SizedBox(height: 8),
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(VeilRadius.lg),
            child: _map(context, cover: true),
          ),
        ),
        if (state.connectionError != null) ...[
          const SizedBox(height: 8),
          ErrorPanel(state: state, compact: true),
        ],
        const SizedBox(height: 8),
        _ServerCard(state: state, server: _server, onTap: onPickServer),
        const SizedBox(height: 8),
        // The phone had no way to start a tunnel from this page at all: the
        // wide layout's button lives in the status bar, which is button-less
        // when compact.
        PrimaryActionButton(
          label: connected ? 'Disconnect' : 'Connect',
          busy: state.isBusyConnecting,
          danger: connected,
          onTap: state.toggleConnection,
          onCancel: state.disconnect,
        ),
        const SizedBox(height: 8),
        _SecurityPanel(state: state, compact: true),
      ],
    );
  }
}

// ── Status bar ───────────────────────────────────────────────────────────────

class _StatusBar extends StatelessWidget {
  const _StatusBar({
    required this.state,
    required this.server,
    this.compact = false,
  });

  final AppState state;
  final ServerConfig? server;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final connected = state.isConnected;
    final busy = state.isBusyConnecting;
    final origin = state.origin;

    final route = server == null
        ? 'No location selected'
        : origin.country.isEmpty
            ? server!.city
            : '${countryName(origin.country)} → ${server!.city}';

    return Container(
      padding: EdgeInsets.fromLTRB(compact ? 12 : 16, 12, compact ? 12 : 16, 12),
      decoration: BoxDecoration(
        color: VeilColors.surface.withValues(alpha: 0.86),
        border: Border.all(color: VeilColors.border),
        borderRadius: BorderRadius.circular(VeilRadius.md),
      ),
      child: Row(
        children: [
          _StatePill(state: state.vpnState),
          SizedBox(width: compact ? 10 : 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  route,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: VeilText.display(size: compact ? 14 : 16, weight: 600),
                ),
                const SizedBox(height: 3),
                _MetaLine(state: state, server: server, compact: compact),
              ],
            ),
          ),
          if (!compact) ...[
            const SizedBox(width: 12),
            _BarButton(
              label: connected ? 'Disconnect' : 'Connect',
              danger: connected,
              busy: busy,
              // Stopping is already a teardown; there is nothing to abandon.
              // Connecting is the one worth being able to walk away from.
              busyLabel: state.vpnState == VpnState.disconnecting
                  ? 'Stopping…'
                  : 'Cancel',
              onTap: state.vpnState == VpnState.disconnecting
                  ? null
                  : state.toggleConnection,
            ),
          ],
        ],
      ),
    );
  }
}

/// Session, public IP and protocol — the row under the route in the design.
class _MetaLine extends StatelessWidget {
  const _MetaLine({
    required this.state,
    required this.server,
    required this.compact,
  });

  final AppState state;
  final ServerConfig? server;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final connected = state.isConnected;

    // While the tunnel is up the address the world sees is the server's; while
    // it is down it is whatever the panel saw us arrive from. Both come from
    // data we already hold, so nothing is asked of a third-party lookup
    // service.
    final publicIp = connected
        ? (server?.address ?? '—')
        : (state.origin.ip.isEmpty ? '—' : state.origin.ip);

    final stats = state.vpnStats;
    final items = <(String, String, Color?)>[
      ('Session', formatDuration(stats.duration), null),
      // How much has actually moved this session, not just how fast it is
      // moving right now — the speeds are already on the card below.
      (
        'Transferred',
        '↓ ${formatBytes(stats.downloadTotal)}  ↑ ${formatBytes(stats.uploadTotal)}',
        null
      ),
      ('Public IP', publicIp, null),
      if (server != null) ('Protocol', server!.protoLabel, null),
    ];

    return Wrap(
      spacing: 16,
      runSpacing: 2,
      children: [
        for (final (label, value, colour) in items)
          // Each pair is bounded by the wrap's line width, so a long hostname
          // has to be allowed to ellipsise rather than overflow the row.
          ConstrainedBox(
            constraints: BoxConstraints(maxWidth: compact ? 220 : 320),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(label,
                    style: VeilText.ui(
                        size: compact ? 10.5 : 11.5, color: VeilColors.muted)),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    value,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: VeilText.mono(
                        size: compact ? 10.5 : 11.5,
                        color: colour ?? VeilColors.text2),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _StatePill extends StatelessWidget {
  const _StatePill({required this.state});

  final VpnState state;

  @override
  Widget build(BuildContext context) {
    final (label, colour) = switch (state) {
      VpnState.connected => ('CONNECTED', VeilColors.accent),
      VpnState.connecting => ('CONNECTING', VeilColors.warn),
      VpnState.disconnecting => ('STOPPING', VeilColors.warn),
      VpnState.error => ('ERROR', VeilColors.danger),
      VpnState.disconnected => ('OFFLINE', VeilColors.muted),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: colour.withValues(alpha: 0.13),
        borderRadius: BorderRadius.circular(VeilRadius.pill),
        border: Border.all(color: colour.withValues(alpha: 0.32)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _Dot(colour: colour, pulsing: state == VpnState.connecting),
          const SizedBox(width: 8),
          Text(label,
              style: VeilText.ui(
                  size: 11, weight: 700, color: colour, letterSpacing: 0.9)),
        ],
      ),
    );
  }
}

class _Dot extends StatefulWidget {
  const _Dot({required this.colour, this.pulsing = false});

  final Color colour;
  final bool pulsing;

  @override
  State<_Dot> createState() => _DotState();
}

class _DotState extends State<_Dot> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );

  @override
  void initState() {
    super.initState();
    if (widget.pulsing) _c.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(covariant _Dot old) {
    super.didUpdateWidget(old);
    if (widget.pulsing && !_c.isAnimating) {
      _c.repeat(reverse: true);
    } else if (!widget.pulsing && _c.isAnimating) {
      _c.stop();
      _c.value = 1;
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: _c,
        builder: (context, _) {
          final o = widget.pulsing ? 0.35 + 0.65 * _c.value : 1.0;
          return Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: widget.colour.withValues(alpha: o),
              boxShadow: [
                BoxShadow(
                    color: widget.colour.withValues(alpha: 0.7 * o),
                    blurRadius: 8),
              ],
            ),
          );
        },
      );
}

class _BarButton extends StatelessWidget {
  const _BarButton({
    required this.label,
    required this.onTap,
    this.danger = false,
    this.busy = false,
    this.busyLabel = 'Working…',
  });

  final String label;
  final VoidCallback? onTap;
  final bool danger;
  final bool busy;
  final String busyLabel;

  @override
  Widget build(BuildContext context) {
    final colour = danger ? VeilColors.danger : VeilColors.accent;
    final foreground = danger ? colour : VeilColors.onAccent;
    return Clickable(
      enabled: onTap != null,
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          height: 38,
          padding: const EdgeInsets.symmetric(horizontal: 20),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: danger ? colour.withValues(alpha: 0.12) : colour,
            border: Border.all(
                color: danger ? colour.withValues(alpha: 0.5) : colour),
            borderRadius: BorderRadius.circular(VeilRadius.sm),
          ),
          // The busy state keeps its words. It used to swap the label out for a
          // bare spinner, and the spinner took the theme's primary colour —
          // which is the accent, the same green the button is filled with. The
          // result was a blank green slab for as long as the handshake took,
          // reported as "the text disappears when I press connect".
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (busy) ...[
                SizedBox(
                  width: 13,
                  height: 13,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: foreground),
                ),
                const SizedBox(width: 8),
              ],
              Text(
                busy ? busyLabel : label,
                style: VeilText.ui(size: 13, weight: 600, color: foreground),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Server card ──────────────────────────────────────────────────────────────

class _ServerCard extends StatelessWidget {
  const _ServerCard({
    required this.state,
    required this.server,
    required this.onTap,
  });

  final AppState state;
  final ServerConfig? server;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final s = server;
    final down = formatSpeed(state.vpnStats.downloadSpeed);
    final up = formatSpeed(state.vpnStats.uploadSpeed);
    final ping = s == null ? null : state.pings[s.id];

    return _Panel(
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              CountryFlagBox(
                country: s?.country ?? '',
                fallback: s == null ? '—' : s.name,
                width: 44,
                height: 34,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      s?.displayName ?? 'Choose a location',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: VeilText.display(size: 15, weight: 600),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      s == null
                          ? 'Tap to pick a server'
                          : [
                              if (s.place.isNotEmpty) s.place,
                              s.address,
                              if (ping != null && ping >= 0) '$ping ms',
                              if (s.load != null) '${s.load}% load',
                            ].join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: VeilText.ui(size: 11.5, color: VeilColors.muted),
                    ),
                  ],
                ),
              ),
              if (ping != null)
                Icon(Icons.circle, size: 8, color: pingColour(ping)),
            ],
          ),
          const SizedBox(height: 14),
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: SpeedTile(
                    label: 'Download',
                    value: down.value,
                    unit: down.unit,
                    icon: Icons.south_rounded,
                    color: VeilColors.accent,
                    spark: state.downHistory,
                    compact: true,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: SpeedTile(
                    label: 'Upload',
                    value: up.value,
                    unit: up.unit,
                    icon: Icons.north_rounded,
                    color: VeilColors.upload,
                    spark: state.upHistory,
                    compact: true,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ── Security panel ───────────────────────────────────────────────────────────

/// Every guard, at a glance, in about a third of the height the stacked rows
/// took.
///
/// The full wording for each one lives in its tooltip: the panel's job on the
/// connect page is to say "all good" or "look here", not to be read line by
/// line.
class _SecurityPanel extends StatelessWidget {
  const _SecurityPanel({required this.state, this.compact = false});

  final AppState state;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final leaks = state.leaks;
    final connected = state.isConnected;
    final chips = <_GuardChip>[
      _GuardChip(
        label: 'Kill switch',
        detail: state.killSwitchEnabled
            ? (state.killSwitchEngaged ? 'Engaged — traffic held' : 'On')
            : 'Off',
        tone: state.killSwitchEngaged
            ? _Tone.warn
            : state.killSwitchEnabled
                ? _Tone.good
                : _Tone.off,
      ),
      _GuardChip(
        label: 'DNS',
        detail: _dnsLabel(leaks.dns, connected),
        tone: _tone(leaks.dns),
      ),
      _GuardChip(
        label: 'IPv6',
        detail: _label(leaks.ipv6, connected, good: 'Blocked', bad: 'Leaking'),
        tone: _tone(leaks.ipv6),
      ),
      _GuardChip(
        label: 'WebRTC',
        detail:
            _label(leaks.webrtc, connected, good: 'Protected', bad: 'Exposed'),
        tone: _tone(leaks.webrtc),
      ),
      _GuardChip(
        label: 'Timezone',
        detail: leaks.timezoneDetail ??
            _label(leaks.timezone, connected,
                good: 'Consistent', bad: 'Mismatch'),
        tone: _tone(leaks.timezone),
      ),
      _GuardChip(
        label: 'Exit IP',
        detail: leaks.exitDetail ??
            _label(leaks.exitIp, connected, good: 'Hidden', bad: 'Exposed'),
        tone: _tone(leaks.exitIp),
      ),
      _GuardChip(
        label: 'LAN',
        detail: _label(leaks.lan, connected, good: 'Silent', bad: 'Announcing'),
        tone: _tone(leaks.lan),
      ),
      if (Storage.I.quicGuard)
        _GuardChip(
          label: 'QUIC',
          detail: _label(leaks.quic, connected,
              good: 'Forced to TCP', bad: 'Escaping'),
          tone: _tone(leaks.quic),
        ),
      _GuardChip(
        label: 'Ads',
        detail: Storage.I.blockAds ? 'Blocked' : 'Off',
        tone: Storage.I.blockAds ? _Tone.good : _Tone.off,
      ),
    ];

    final leaking = leaks.anyLeaking;

    return _Panel(
      padding: const EdgeInsets.fromLTRB(13, 10, 13, 11),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Text('SECURITY',
                  style: VeilText.ui(
                      size: 9.5,
                      weight: 700,
                      color: VeilColors.muted,
                      letterSpacing: 1.4)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  leaking
                      ? 'A guard is leaking'
                      : connected
                          ? 'All guards holding'
                          : 'Idle',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: VeilText.ui(
                    size: 9.5,
                    color: leaking ? VeilColors.danger : VeilColors.muted,
                  ),
                ),
              ),
              if (leaking)
                Icon(Icons.warning_amber_rounded,
                    size: 14, color: VeilColors.danger),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(spacing: 6, runSpacing: 6, children: chips),
        ],
      ),
    );
  }

  static _Tone _tone(GuardState s) => switch (s) {
        GuardState.off => _Tone.off,
        GuardState.checking => _Tone.checking,
        GuardState.leaking => _Tone.bad,
        _ => _Tone.good,
      };

  static String _dnsLabel(GuardState s, bool connected) => switch (s) {
        GuardState.off => 'Off',
        GuardState.checking => connected ? 'Checking…' : 'Idle',
        GuardState.leaking => 'Leaking',
        _ => 'Through tunnel',
      };

  static String _label(GuardState s, bool connected,
          {required String good, required String bad}) =>
      switch (s) {
        GuardState.off => 'Off',
        GuardState.checking => connected ? 'Checking…' : 'Idle',
        GuardState.leaking => bad,
        _ => good,
      };
}

enum _Tone { good, bad, warn, off, checking }

class _GuardChip extends StatelessWidget {
  const _GuardChip({
    required this.label,
    required this.detail,
    required this.tone,
  });

  final String label;
  final String detail;
  final _Tone tone;

  @override
  Widget build(BuildContext context) {
    final colour = switch (tone) {
      _Tone.good => VeilColors.accent,
      _Tone.bad => VeilColors.danger,
      _Tone.warn => VeilColors.warn,
      _ => VeilColors.muted,
    };
    final icon = switch (tone) {
      _Tone.good => Icons.check_rounded,
      _Tone.bad => Icons.close_rounded,
      _Tone.warn => Icons.priority_high_rounded,
      _Tone.checking => Icons.more_horiz_rounded,
      _Tone.off => Icons.remove_rounded,
    };

    return Tooltip(
      message: '$label · $detail',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: colour.withValues(alpha: 0.10),
          border: Border.all(color: colour.withValues(alpha: 0.28)),
          borderRadius: BorderRadius.circular(VeilRadius.pill),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 11, color: colour),
            const SizedBox(width: 5),
            Text(label,
                style: VeilText.ui(size: 10.5, weight: 600, color: colour)),
          ],
        ),
      ),
    );
  }
}

/// The frosted card the map's overlays sit in.
class _Panel extends StatelessWidget {
  const _Panel({
    required this.child,
    this.onTap,
    this.padding = const EdgeInsets.fromLTRB(15, 14, 15, 14),
  });

  final Widget child;
  final VoidCallback? onTap;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) => Clickable(enabled: onTap != null, child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          padding: padding,
          decoration: BoxDecoration(
            color: VeilColors.surface.withValues(alpha: 0.9),
            border: Border.all(color: VeilColors.border),
            borderRadius: BorderRadius.circular(VeilRadius.md),
            boxShadow: [
              BoxShadow(
                  color: VeilColors.shadow(0.45),
                  blurRadius: 34,
                  offset: Offset(0, 14)),
            ],
          ),
          child: child,
        ),
      ));
}
