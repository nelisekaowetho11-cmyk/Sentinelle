import 'package:flutter/material.dart';

import 'dart:io';

import '../models/models.dart';
import '../services/storage.dart';
import '../services/vpn/elevation.dart';
import '../services/vpn/vpn_engine.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/tunnel_orb.dart';
import '../widgets/update_banner.dart';
import 'home_detailed.dart';
import 'shell.dart' show mobileTabBarClearance;

/// The Connect page, in one of two layouts.
///
/// Detailed (the default) is the live map with the route, session summary and
/// security panel. Simple is the single-orb page, kept for anyone who prefers
/// it. [Storage.detailedHome] chooses; the switch is in Settings and on the
/// page itself.
class HomeScreen extends StatelessWidget {
  const HomeScreen({
    super.key,
    required this.state,
    required this.onPickServer,
  });

  final AppState state;
  final VoidCallback onPickServer;

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 900;
    final bottomClearance = wide ? 18.0 : mobileTabBarClearance(context);
    final detailed = Storage.I.detailedHome;

    return Container(
      decoration: veilPageGlow(),
      child: SafeArea(
        bottom: false,
        child: LayoutBuilder(
          builder: (context, box) {
            final available = box.maxHeight - bottomClearance;
            return Padding(
              padding: EdgeInsets.fromLTRB(16, 6, 16, bottomClearance),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _ViewModeBar(state: state, detailed: detailed),
                  const SizedBox(height: 8),
                  Expanded(
                    child: detailed
                        ? DetailedHome(
                            state: state,
                            onPickServer: onPickServer,
                          )
                        : _Content(
                            state: state,
                            onPickServer: onPickServer,
                            height: available - 34,
                            wide: wide,
                          ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

/// Detailed / Simple switch, kept on the page so the two layouts are one tap
/// apart rather than buried in Settings.
class _ViewModeBar extends StatelessWidget {
  const _ViewModeBar({required this.state, required this.detailed});

  final AppState state;
  final bool detailed;

  @override
  Widget build(BuildContext context) {
    Widget tab(String label, IconData icon, bool on) => Clickable(
          enabled: !on,
          child: GestureDetector(
          onTap: on ? null : () => state.setDetailedHome(!detailed),
          behavior: HitTestBehavior.opaque,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
            decoration: BoxDecoration(
              color: on ? VeilColors.accentTint : Colors.transparent,
              borderRadius: BorderRadius.circular(VeilRadius.pill),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon,
                    size: 14,
                    color: on ? VeilColors.accent : VeilColors.muted),
                const SizedBox(width: 6),
                Text(label,
                    style: VeilText.ui(
                        size: 11.5,
                        weight: 600,
                        color: on ? VeilColors.accent : VeilColors.muted)),
              ],
            ),
          ),
          ),
        );

    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        Container(
          padding: const EdgeInsets.all(2),
          decoration: BoxDecoration(
            color: VeilColors.surface2,
            border: Border.all(color: VeilColors.borderSoft),
            borderRadius: BorderRadius.circular(VeilRadius.pill),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              tab('Detailed', Icons.dashboard_rounded, detailed),
              tab('Simple', Icons.circle_outlined, !detailed),
            ],
          ),
        ),
      ],
    );
  }
}

class _Content extends StatelessWidget {
  const _Content({
    required this.state,
    required this.onPickServer,
    required this.height,
    required this.wide,
  });

  final AppState state;
  final VoidCallback onPickServer;
  final double height;
  final bool wide;

  // Optional rows are dropped on short viewports rather than squeezed. The orb
  // block is Expanded, so it absorbs whatever is left after everything else has
  // been laid out — no hand-computed height budget to drift out of date.
  static const _tilesMinHeight = 560.0;
  static const _quotaMinHeight = 660.0;

  @override
  Widget build(BuildContext context) {
    final needsAdmin = state.needsElevation;
    final killed = state.killSwitchEngaged;
    final hasBanner = needsAdmin ||
        killed ||
        state.blockedReason != null ||
        state.connectionError != null ||
        state.slowServerWarning != null;
    final showTiles = height >= _tilesMinHeight;
    final showQuota = showTiles && height >= _quotaMinHeight;

    final down = formatSpeed(state.vpnStats.downloadSpeed);
    final up = formatSpeed(state.vpnStats.uploadSpeed);
    final server = state.activeServer ?? state.selectedServer;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Header(state: state),

        if (UpdateBanner.visibleFor(state)) ...[
          const SizedBox(height: 10),
          UpdateBanner(state: state, compact: true),
        ],

        if (hasBanner) ...[
          const SizedBox(height: 10),
          if (needsAdmin)
            _Banner(
              icon: Icons.admin_panel_settings_rounded,
              color: VeilColors.warn,
              title: 'VPN mode needs administrator rights',
              message: Elevation.canRelaunch
                  ? 'Restart with elevated rights to bring the tunnel up.'
                  : Elevation.manualInstruction,
              action: Elevation.canRelaunch
                  ? _BannerAction(
                      label: 'Restart as admin',
                      onTap: () async {
                        // Declining the UAC prompt leaves us running exactly
                        // as we were, so say so instead of failing silently.
                        final messenger = ScaffoldMessenger.maybeOf(context);
                        await state.shutdown();
                        if (await Elevation.relaunchElevated()) exit(0);
                        messenger?.showSnackBar(SnackBar(
                          backgroundColor: VeilColors.surface,
                          content: Text(
                            'Not restarted. ${Elevation.manualInstruction}',
                            style: VeilText.ui(size: 12.5),
                          ),
                        ));
                      },
                    )
                  : null,
            )
          // The kill switch outranks the ordinary "could not connect" banner:
          // the user needs to know traffic is being held, not just that a
          // connection attempt failed.
          else if (killed)
            _Banner(
              icon: Icons.block_rounded,
              color: VeilColors.danger,
              title: 'Kill switch active — traffic is blocked',
              message: state.waitingForNetwork
                  ? 'Waiting for the internet to come back, then reconnecting.'
                  : 'The tunnel dropped. Reconnecting…',
              secondary: _BannerAction(
                label: 'Turn off',
                onTap: state.releaseKillSwitch,
              ),
              action: _BannerAction(
                label: 'Retry now',
                onTap: state.retryNow,
              ),
            )
          else
            _Banner(
              icon: state.blockedReason != null
                  ? Icons.report_gmailerrorred_rounded
                  : state.connectionError != null
                      ? Icons.error_outline_rounded
                      : Icons.speed_rounded,
              color: state.connectionError != null
                  ? VeilColors.danger
                  : VeilColors.warn,
              title: state.blockedReason != null
                  ? 'Account not active'
                  : state.connectionError != null
                      ? 'Could not connect'
                      : 'Slow server',
              message: state.blockedReason ??
                  state.connectionError ??
                  state.slowServerWarning!,
            ),
        ],

        Expanded(
          child: LayoutBuilder(
            builder: (context, box) {
              // Headline block ≈ 92, timer block ≈ 50.
              final orb = (box.maxHeight - 150).clamp(
                96.0,
                wide ? 200.0 : 236.0,
              );
              return Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _StateHeadline(state: state, server: server),
                  const SizedBox(height: 6),
                  Flexible(
                    child: TunnelOrb(
                      state: state.vpnState,
                      size: orb,
                      // The orb is the main control on this layout, so it
                      // has to be able to call off an attempt too.
                      onTap: state.vpnState == VpnState.disconnecting
                          ? null
                          : state.toggleConnection,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    formatDuration(state.vpnStats.duration),
                    style: VeilText.mono(size: wide ? 23 : 26, weight: 500),
                  ),
                  const SizedBox(height: 1),
                  Text('SESSION', style: VeilText.label(size: 10)),
                ],
              );
            },
          ),
        ),

        const SizedBox(height: 8),
        _ConnectButton(state: state),
        const SizedBox(height: 10),
        _ServerCard(server: server, state: state, onTap: onPickServer),

        if (showTiles) ...[
          const SizedBox(height: 10),
          // IntrinsicHeight keeps both tiles the same height without asking a
          // Row for `stretch`, which would demand an unbounded height here.
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

        if (showQuota) ...[
          const SizedBox(height: 10),
          _QuotaCard(state: state),
        ],
      ],
    );
  }
}

class _StateHeadline extends StatelessWidget {
  const _StateHeadline({required this.state, required this.server});
  final AppState state;
  final ServerConfig? server;

  @override
  Widget build(BuildContext context) {
    final headline = switch (state.vpnState) {
      VpnState.connected => "You're protected",
      VpnState.connecting => 'Establishing tunnel…',
      VpnState.disconnecting => 'Closing tunnel…',
      VpnState.error => 'Connection failed',
      VpnState.disconnected => 'Not connected',
    };
    final subline = switch (state.vpnState) {
      VpnState.connected =>
        server == null
            ? 'Encrypted tunnel active'
            : 'Routed through ${server!.displayLocation}',
      VpnState.connecting =>
        'Negotiating with ${server?.displayLocation ?? 'the server'}',
      VpnState.disconnecting => 'Restoring your direct connection',
      VpnState.error => 'Check the details below',
      VpnState.disconnected => 'Your traffic is not being protected',
    };

    return Column(
      children: [
        StatusPill(
          label: _label(state.vpnState),
          color: _color(state.vpnState),
          pulse: state.vpnState == VpnState.connected,
        ),
        const SizedBox(height: 10),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 260),
          child: Text(
            headline,
            key: ValueKey(headline),
            textAlign: TextAlign.center,
            style: VeilText.display(size: 23, weight: 600),
          ),
        ),
        const SizedBox(height: 3),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 260),
          child: Text(
            subline,
            key: ValueKey(subline),
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: VeilText.ui(size: 12.5, color: VeilColors.muted),
          ),
        ),
      ],
    );
  }

  static String _label(VpnState s) => switch (s) {
    VpnState.connected => 'Connected',
    VpnState.connecting => 'Connecting',
    VpnState.disconnecting => 'Disconnecting',
    VpnState.error => 'Error',
    VpnState.disconnected => 'Disconnected',
  };

  static Color _color(VpnState s) => switch (s) {
    VpnState.connected => VeilColors.accent,
    VpnState.connecting || VpnState.disconnecting => VeilColors.warn,
    VpnState.error => VeilColors.danger,
    VpnState.disconnected => VeilColors.muted,
  };
}

class _Header extends StatelessWidget {
  const _Header({required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final p = state.profile;
    return SizedBox(
      height: 40,
      child: Row(
        children: [
          const VeilMark(size: 28),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  state.brand,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: VeilText.display(size: 16, weight: 600),
                ),
                if (p != null)
                  Text(
                    p.name.isEmpty ? p.username : p.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: VeilText.ui(size: 11, color: VeilColors.muted),
                  ),
              ],
            ),
          ),
          if (p != null && p.daysLeft != null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: VeilColors.surface,
                borderRadius: BorderRadius.circular(VeilRadius.pill),
                border: Border.all(color: VeilColors.border),
              ),
              child: Text(
                '${p.daysLeft}d left',
                style: VeilText.mono(size: 11, color: VeilColors.text2),
              ),
            ),
        ],
      ),
    );
  }
}

class _BannerAction {
  const _BannerAction({required this.label, required this.onTap});
  final String label;
  final VoidCallback onTap;
}

class _Banner extends StatelessWidget {
  const _Banner({
    required this.icon,
    required this.color,
    required this.title,
    required this.message,
    this.action,
    this.secondary,
  });

  final IconData icon;
  final Color color;
  final String title;
  final String message;

  /// Rendered as the filled button on the right.
  final _BannerAction? action;

  /// The way out, rendered as a quieter text button beside it.
  final _BannerAction? secondary;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(11),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.10),
      borderRadius: BorderRadius.circular(VeilRadius.md),
      border: Border.all(color: color.withValues(alpha: 0.30)),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 17, color: color),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                title,
                style: VeilText.ui(size: 12.5, weight: 600, color: color),
              ),
              const SizedBox(height: 1),
              Text(
                message,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: VeilText.ui(
                  size: 11.5,
                  color: VeilColors.text2,
                  height: 1.4,
                ),
              ),
            ],
          ),
        ),
        if (secondary != null) ...[
          const SizedBox(width: 4),
          TextButton(
            onPressed: secondary!.onTap,
            style: TextButton.styleFrom(
              foregroundColor: VeilColors.muted,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              minimumSize: const Size(0, 32),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: Text(secondary!.label,
                style: VeilText.ui(size: 11.5, weight: 500)),
          ),
        ],
        if (action != null) ...[
          const SizedBox(width: 6),
          FilledButton(
            onPressed: action!.onTap,
            style: FilledButton.styleFrom(
              backgroundColor: color,
              foregroundColor: VeilColors.bg,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              minimumSize: const Size(0, 32),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(VeilRadius.sm),
              ),
            ),
            child: Text(action!.label,
                style: VeilText.ui(size: 11.5, weight: 600)),
          ),
        ],
      ],
    ),
  );
}

class _ConnectButton extends StatelessWidget {
  const _ConnectButton({required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final connected = state.isConnected;
    final busy = state.isBusyConnecting;
    final canUse = state.profile?.canConnect ?? false;

    return SizedBox(
      height: 52,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOutCubic,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(VeilRadius.md),
          boxShadow: connected || !canUse
              ? null
              : [
                  BoxShadow(
                    color: VeilColors.accent.withValues(alpha: 0.28),
                    blurRadius: 24,
                    offset: const Offset(0, 6),
                  ),
                ],
        ),
        child: FilledButton(
          // Tappable while busy on purpose: `toggleConnection` tears a
          // half-built tunnel down, which is the only way out of a handshake
          // against a server that is never going to answer.
          onPressed: (busy && state.vpnState == VpnState.disconnecting) ||
                  (!busy && !canUse)
              ? null
              : state.toggleConnection,
          style: FilledButton.styleFrom(
            backgroundColor: connected
                ? VeilColors.danger.withValues(alpha: 0.16)
                : VeilColors.accent,
            foregroundColor: connected
                ? VeilColors.danger
                : VeilColors.onAccent,
            disabledBackgroundColor: VeilColors.surface2,
            disabledForegroundColor: VeilColors.muted,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(VeilRadius.md),
              side: BorderSide(
                color: connected
                    ? VeilColors.danger.withValues(alpha: 0.35)
                    : Colors.transparent,
              ),
            ),
          ),
          // Busy keeps the words and only swaps the icon for a spinner. A bare
          // indeterminate ring left the button as a featureless green slab for
          // the length of the handshake, which read as the label vanishing.
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 200),
            child: Builder(
              key: ValueKey('$busy$connected$canUse'),
              builder: (context) {
                final foreground = !canUse
                    ? VeilColors.muted
                    : connected
                        ? VeilColors.danger
                        : VeilColors.onAccent;
                return Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (busy)
                      SizedBox(
                        width: 17,
                        height: 17,
                        child: CircularProgressIndicator(
                            strokeWidth: 2.2, color: foreground),
                      )
                    else
                      Icon(
                        connected
                            ? Icons.power_settings_new_rounded
                            : Icons.bolt_rounded,
                        size: 18,
                      ),
                    const SizedBox(width: 9),
                    Text(
                      busy
                          ? (state.vpnState == VpnState.disconnecting
                              ? 'Stopping…'
                              : 'Connecting… tap to cancel')
                          : !canUse
                              ? 'Unavailable'
                              : connected
                                  ? 'Disconnect'
                                  : 'Connect',
                      style: VeilText.ui(size: 15, weight: 600)
                          .copyWith(color: foreground),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _ServerCard extends StatelessWidget {
  const _ServerCard({
    required this.server,
    required this.state,
    required this.onTap,
  });

  final ServerConfig? server;
  final AppState state;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    // Slide + fade whenever the chosen server changes.
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 340),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      transitionBuilder: (child, anim) => FadeTransition(
        opacity: anim,
        child: SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0.10, 0),
            end: Offset.zero,
          ).animate(anim),
          child: child,
        ),
      ),
      layoutBuilder: (current, previous) => Stack(
        alignment: Alignment.centerLeft,
        children: [...previous, ?current],
      ),
      child: KeyedSubtree(
        key: ValueKey(server?.id ?? -1),
        child: _ServerCardBody(server: server, state: state, onTap: onTap),
      ),
    );
  }
}

class _ServerCardBody extends StatelessWidget {
  const _ServerCardBody({
    required this.server,
    required this.state,
    required this.onTap,
  });

  final ServerConfig? server;
  final AppState state;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    if (server == null) {
      return VeilCard(
        onTap: onTap,
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 12),
        child: Row(
          children: [
            const FlagChip(country: '', fallback: '?', size: 38),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'No servers assigned to your account yet',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: VeilText.ui(size: 12.5, color: VeilColors.muted),
              ),
            ),
          ],
        ),
      );
    }

    final s = server!;
    final ping = state.pings[s.id];

    return VeilCard(
      onTap: onTap,
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
      child: Row(
        children: [
          FlagChip(country: s.country, fallback: s.name, size: 38),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('CURRENT', style: VeilText.label(size: 9.5)),
                const SizedBox(height: 2),
                Text(
                  s.displayName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: VeilText.ui(size: 14, weight: 600),
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Flexible(
                      child: ProtoChip(
                        protocol: s.protocol,
                        label: s.protoLabel,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      ping == null
                          ? '— ms'
                          : (ping < 0 ? 'unreachable' : '$ping ms'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: VeilText.mono(
                        size: 10.5,
                        color: ping != null && ping < 0
                            ? VeilColors.danger
                            : VeilColors.muted,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            decoration: BoxDecoration(
              color: VeilColors.tint(0.06),
              borderRadius: BorderRadius.circular(VeilRadius.pill),
            ),
            child: Text(
              'Change',
              style: VeilText.ui(size: 12, weight: 500, color: VeilColors.text),
            ),
          ),
        ],
      ),
    );
  }
}

class _QuotaCard extends StatelessWidget {
  const _QuotaCard({required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final p = state.profile;
    if (p == null) return const SizedBox.shrink();

    return VeilCard(
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Text('DATA ALLOWANCE', style: VeilText.label(size: 9.5)),
              const Spacer(),
              Text(
                p.unlimited
                    ? 'Unlimited'
                    : '${p.trafficUsedGb.toStringAsFixed(2)} / ${p.trafficLimitGb.toStringAsFixed(0)} GB',
                style: VeilText.mono(size: 11, color: VeilColors.text2),
              ),
            ],
          ),
          const SizedBox(height: 7),
          QuotaBar(pct: p.unlimited ? 0 : p.trafficPct),
          const SizedBox(height: 7),
          Row(
            children: [
              Flexible(
                child: Text(
                  p.unlimited
                      ? 'No data cap on this plan'
                      : '${(p.trafficLeftGb ?? 0).toStringAsFixed(2)} GB remaining',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: VeilText.ui(size: 11, color: VeilColors.muted),
                ),
              ),
              const SizedBox(width: 10),
              if (p.expires.isNotEmpty)
                Flexible(
                  child: Text(
                    'Expires ${p.expires}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.right,
                    style: VeilText.mono(size: 10.5, color: VeilColors.muted),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
