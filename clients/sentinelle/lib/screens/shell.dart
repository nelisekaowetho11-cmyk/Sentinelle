import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';

import '../branding.dart';
import '../models/models.dart';
import '../services/storage.dart';
import '../services/vpn/vpn_engine.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/window_chrome.dart';
import 'home_screen.dart';
import 'locations_screen.dart';
import 'settings_screen.dart';
import 'sources_screen.dart';
import 'stats_screen.dart';

class VeilShell extends StatefulWidget {
  const VeilShell({super.key, required this.state});
  final AppState state;

  @override
  State<VeilShell> createState() => _VeilShellState();
}

class _VeilShellState extends State<VeilShell> {
  int _tab = 0;

  static const _tabs = <_TabDef>[
    (icon: Icons.shield_rounded, label: 'Connect'),
    (icon: Icons.public_rounded, label: 'Locations'),
    (icon: Icons.account_circle_rounded, label: 'Accounts'),
    (icon: Icons.insights_rounded, label: 'Stats'),
    (icon: Icons.tune_rounded, label: 'Settings'),
  ];

  late bool _sidebarCollapsed = Storage.I.sidebarCollapsed;

  void _go(int i) {
    if (_tab == i) return;
    setState(() => _tab = i);
  }

  void _toggleSidebar() {
    setState(() => _sidebarCollapsed = !_sidebarCollapsed);
    Storage.I.setSidebarCollapsed(_sidebarCollapsed);
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 900;

    final pages = [
      HomeScreen(state: widget.state, onPickServer: () => _go(1)),
      LocationsScreen(state: widget.state, onSelected: () => _go(0)),
      SourcesScreen(state: widget.state),
      StatsScreen(state: widget.state),
      SettingsScreen(state: widget.state),
    ];

    // Cross-fade between tabs instead of a hard cut.
    Widget body(int index) => AnimatedSwitcher(
          duration: const Duration(milliseconds: 260),
          switchInCurve: Curves.easeOutCubic,
          switchOutCurve: Curves.easeInCubic,
          transitionBuilder: (child, anim) => FadeTransition(
            opacity: anim,
            child: SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(0, 0.015),
                end: Offset.zero,
              ).animate(anim),
              child: child,
            ),
          ),
          child: KeyedSubtree(key: ValueKey(index), child: pages[index]),
        );

    // Desktop keeps its own title bar in every layout — it is the only way to
    // close the window once the OS chrome is off.
    final Widget inner = wide
        ? Row(
            children: [
              _DesktopSidebar(
                state: widget.state,
                index: _tab,
                tabs: _tabs,
                onSelect: _go,
                collapsed: _sidebarCollapsed,
                onToggleCollapsed: _toggleSidebar,
              ),
              Expanded(
                child: Container(color: VeilColors.bg, child: body(_tab)),
              ),
            ],
          )
        : Stack(
            children: [
              Positioned.fill(child: body(_tab)),
              Positioned(
                left: 12,
                right: 12,
                bottom: _barBottom(context),
                child: _FloatingTabBar(index: _tab, tabs: _tabs, onSelect: _go),
              ),
            ],
          );

    if (usesCustomChrome) {
      return Scaffold(
        body: Column(
          children: [
            VeilTitleBar(
              title: kAppName,
              subtitle: _statusText(widget.state),
              accent: widget.state.isConnected,
            ),
            Expanded(child: inner),
          ],
        ),
      );
    }

    // Mobile paints behind the system bars (edge-to-edge) and insets by hand:
    // every page in the narrow layout has its own SafeArea, and the floating
    // tab bar sits above the navigation inset.
    //
    // The wide layout has no such handling — it was written for a desktop
    // window, where there are no system bars to avoid. On a tablet that put
    // the sidebar under the clock and the page under the navigation pill.
    // Tablets run full screen (see main.dart), so this inset is normally zero;
    // it is here for the devices and windowed modes that decline to hide them.
    return Scaffold(body: wide ? SafeArea(child: inner) : inner);
  }

  /// Keeps the floating bar clear of the system navigation area.
  static double _barBottom(BuildContext context) {
    final navInset = MediaQuery.viewPaddingOf(context).bottom;
    return navInset > 0 ? navInset + 6 : 14.0;
  }

  static String _statusText(AppState s) => switch (s.vpnState) {
        VpnState.connected => 'Connected',
        VpnState.connecting => 'Connecting…',
        VpnState.disconnecting => 'Disconnecting…',
        VpnState.error => 'Error',
        VpnState.disconnected => 'Idle',
      };
}

typedef _TabDef = ({IconData icon, String label});

/// Height the mobile content must keep clear so the floating bar never covers
/// anything, including the system navigation inset.
double mobileTabBarClearance(BuildContext context) {
  final navInset = MediaQuery.viewPaddingOf(context).bottom;
  return _FloatingTabBar.height + (navInset > 0 ? navInset + 6 : 14) + 10;
}

class _FloatingTabBar extends StatelessWidget {
  const _FloatingTabBar({
    required this.index,
    required this.tabs,
    required this.onSelect,
  });

  static const height = 62.0;

  final int index;
  final List<_TabDef> tabs;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(VeilRadius.pill),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
        child: Container(
          height: height,
          decoration: BoxDecoration(
            color: VeilColors.elev.withValues(alpha: 0.82),
            borderRadius: BorderRadius.circular(VeilRadius.pill),
            border: Border.all(color: VeilColors.tint(0.08)),
            boxShadow: [
              BoxShadow(
                  color: VeilColors.shadow(0.40), blurRadius: 30, offset: Offset(0, 10)),
            ],
          ),
          child: Row(
            children: [
              for (var i = 0; i < tabs.length; i++)
                Expanded(
                  child: InkWell(
                    borderRadius: BorderRadius.circular(VeilRadius.pill),
                    onTap: () => onSelect(i),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        AnimatedContainer(
                          duration: const Duration(milliseconds: 200),
                          curve: Curves.easeOutCubic,
                          padding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 3),
                          decoration: BoxDecoration(
                            color: i == index
                                ? VeilColors.accent.withValues(alpha: 0.16)
                                : Colors.transparent,
                            borderRadius: BorderRadius.circular(VeilRadius.pill),
                          ),
                          child: Icon(
                            tabs[i].icon,
                            size: 20,
                            color:
                                i == index ? VeilColors.accent : VeilColors.muted,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          tabs[i].label,
                          style: VeilText.ui(
                            size: 9.5,
                            weight: 600,
                            color:
                                i == index ? VeilColors.accent : VeilColors.muted,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DesktopSidebar extends StatelessWidget {
  const _DesktopSidebar({
    required this.state,
    required this.index,
    required this.tabs,
    required this.onSelect,
    required this.collapsed,
    required this.onToggleCollapsed,
  });

  static const expandedWidth = 210.0;
  static const collapsedWidth = 62.0;

  final AppState state;
  final int index;
  final List<_TabDef> tabs;
  final ValueChanged<int> onSelect;
  final bool collapsed;
  final VoidCallback onToggleCollapsed;

  @override
  Widget build(BuildContext context) {
    final p = state.profile;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      width: collapsed ? collapsedWidth : expandedWidth,
      decoration: BoxDecoration(
        color: VeilColors.surface,
        border: Border(right: BorderSide(color: VeilColors.border)),
      ),
      padding: EdgeInsets.fromLTRB(collapsed ? 8 : 12, 14, collapsed ? 8 : 12, 14),
      // The width animates, so mid-flight the children are briefly laid out
      // against a size that suits neither state. Clipping keeps that from
      // painting as an overflow stripe.
      clipBehavior: Clip.hardEdge,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _header(),
          const SizedBox(height: 12),
          for (var i = 0; i < tabs.length; i++)
            _SidebarItem(
              icon: tabs[i].icon,
              label: tabs[i].label,
              active: i == index,
              collapsed: collapsed,
              badge: switch (i) {
                1 when state.servers.isNotEmpty => '${state.servers.length}',
                2 when state.sources.sources.isNotEmpty =>
                  '${state.sources.sources.length}',
                _ => null,
              },
              onTap: () => onSelect(i),
            ),
          const Spacer(),
          if (p != null) _quota(p),
          if (!Platform.isAndroid && !collapsed) ...[
            const SizedBox(height: 9),
            Text(
              state.engineOptions.mode == TunnelMode.vpn
                  ? 'VPN mode · full tunnel'
                  : 'Proxy mode · ${state.engineOptions.socksPort}',
              textAlign: TextAlign.center,
              style: VeilText.ui(size: 9.5, color: VeilColors.muted),
            ),
          ],
        ],
      ),
    );
  }

  /// The collapse control lives here, at the top of the menu, because that is
  /// where anyone looks for it.
  ///
  /// It started life as a muted row pinned under the quota card at the very
  /// bottom, which is a place people scan past — the feature may as well not
  /// have existed.
  Widget _header() {
    if (collapsed) {
      return Column(
        children: [
          const VeilMark(size: 28),
          const SizedBox(height: 8),
          _collapseButton(),
        ],
      );
    }
    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: Row(
        children: [
          const VeilMark(size: 30),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(state.brand,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: VeilText.display(size: 15, weight: 600)),
                AnimatedDefaultTextStyle(
                  duration: const Duration(milliseconds: 250),
                  style: VeilText.label(
                    size: 9.5,
                    color: state.isConnected
                        ? VeilColors.accent
                        : VeilColors.muted,
                  ),
                  child: Text(state.isConnected ? 'Protected' : 'Idle'),
                ),
              ],
            ),
          ),
          _collapseButton(),
        ],
      ),
    );
  }

  Widget _collapseButton() => Tooltip(
        message: collapsed ? 'Expand menu' : 'Collapse menu to icons',
        child: Material(
          color: VeilColors.surface2,
          borderRadius: BorderRadius.circular(8),
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: onToggleCollapsed,
            child: Container(
              width: 28,
              height: 28,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: VeilColors.border),
              ),
              child: Icon(
                collapsed
                    ? Icons.keyboard_double_arrow_right_rounded
                    : Icons.keyboard_double_arrow_left_rounded,
                size: 16,
                color: VeilColors.text2,
              ),
            ),
          ),
        ),
      );

  /// Collapsed, the quota is a bare progress bar — enough to notice it running
  /// low, and the tooltip has the numbers.
  Widget _quota(Profile p) {
    final left = p.unlimited
        ? '∞ GB'
        : '${(p.trafficLeftGb ?? 0).toStringAsFixed(1)} GB';
    final days = p.daysLeft == null ? '∞' : '${p.daysLeft}d';

    if (collapsed) {
      return Tooltip(
        message: '${p.username}\n$left left · $days',
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
          child: QuotaBar(pct: p.unlimited ? 0 : p.trafficPct, height: 3),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(11),
      decoration: BoxDecoration(
        color: VeilColors.surface2,
        borderRadius: BorderRadius.circular(VeilRadius.md),
        border: Border.all(color: VeilColors.borderSoft),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('SUBSCRIPTION', style: VeilText.label(size: 9)),
          const SizedBox(height: 4),
          Text(p.username,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: VeilText.mono(size: 12, weight: 500)),
          const SizedBox(height: 8),
          QuotaBar(pct: p.unlimited ? 0 : p.trafficPct, height: 3),
          const SizedBox(height: 5),
          Row(
            children: [
              Text(left,
                  style: VeilText.mono(size: 9.5, color: VeilColors.muted)),
              const Spacer(),
              Text(days,
                  style: VeilText.mono(size: 9.5, color: VeilColors.muted)),
            ],
          ),
        ],
      ),
    );
  }

}

class _SidebarItem extends StatelessWidget {
  const _SidebarItem({
    required this.icon,
    required this.label,
    required this.active,
    required this.onTap,
    this.badge,
    this.collapsed = false,
  });

  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback onTap;
  final String? badge;
  final bool collapsed;

  @override
  Widget build(BuildContext context) {
    final row = collapsed
        ? Stack(
            clipBehavior: Clip.none,
            alignment: Alignment.center,
            children: [
              Icon(icon,
                  size: 18,
                  color: active ? VeilColors.accent : VeilColors.text2),
              if (badge != null)
                Positioned(
                  right: -6,
                  top: -4,
                  child: Container(
                    width: 6,
                    height: 6,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: VeilColors.accent,
                    ),
                  ),
                ),
            ],
          )
        : Row(
            children: [
              Icon(icon,
                  size: 16,
                  color: active ? VeilColors.accent : VeilColors.text2),
              const SizedBox(width: 10),
              Expanded(
                child: Text(label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: VeilText.ui(
                        size: 13,
                        weight: 500,
                        color: active ? VeilColors.text : VeilColors.text2)),
              ),
              if (badge != null)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                  decoration: BoxDecoration(
                    color: VeilColors.surface2,
                    borderRadius: BorderRadius.circular(VeilRadius.pill),
                  ),
                  child: Text(badge!,
                      style:
                          VeilText.mono(size: 9.5, color: VeilColors.text2)),
                ),
            ],
          );

    final item = Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOutCubic,
        decoration: BoxDecoration(
          color: active
              ? VeilColors.accent.withValues(alpha: 0.14)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(VeilRadius.sm),
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(VeilRadius.sm),
            onTap: onTap,
            child: Padding(
              padding: EdgeInsets.symmetric(
                  horizontal: collapsed ? 4 : 10, vertical: collapsed ? 11 : 9),
              child: row,
            ),
          ),
        ),
      ),
    );

    // Collapsed, the icon is the only affordance — the tooltip is what makes
    // it usable rather than a guessing game.
    return collapsed
        ? Tooltip(message: badge == null ? label : '$label · $badge', child: item)
        : item;
  }
}
