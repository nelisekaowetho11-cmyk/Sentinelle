import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../branding.dart';
import '../models/models.dart';
import '../services/storage.dart';
import '../services/routing.dart';
import '../services/vpn/core_manager.dart';
import '../services/vpn/elevation.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'shell.dart' show mobileTabBarClearance;
import 'app_tunnels_screen.dart';
import 'split_tunnel_screen.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, required this.state});
  final AppState state;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  String _appVersion = '';
  String _coreVersion = '';
  bool _installingCore = false;
  double _installProgress = 0;
  String _installNote = '';

  bool get _isDesktop =>
      Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  @override
  void initState() {
    super.initState();
    _loadVersions();
  }

  Future<void> _loadVersions() async {
    final info = await PackageInfo.fromPlatform();
    final core = await widget.state.engine.coreVersion();
    if (!mounted) return;
    setState(() {
      _appVersion = '${info.version} (${info.buildNumber})';
      _coreVersion = core;
    });
  }

  Future<void> _installCore() async {
    setState(() {
      _installingCore = true;
      _installProgress = 0;
      _installNote = 'Starting…';
    });
    try {
      final path = await CoreManager.download(
        CoreKind.singbox,
        onProgress: (p, note) {
          if (mounted) {
            setState(() {
              _installProgress = p;
              _installNote = note;
            });
          }
        },
      );
      await Storage.I.setCorePath(path);
      await _loadVersions();
      if (mounted) showVeilToast(context, 'sing-box installed');
    } on CoreDownloadException catch (e) {
      if (mounted) await _showDownloadFailure(e);
    } catch (e) {
      if (mounted) showVeilToast(context, 'Core install failed: $e', error: true);
    } finally {
      if (mounted) setState(() => _installingCore = false);
    }
  }

  /// The download is the step most likely to be blocked on the networks this
  /// app exists for, so the failure explains the manual route in full.
  Future<void> _showDownloadFailure(CoreDownloadException e) async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: VeilColors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(VeilRadius.lg),
          side: BorderSide(color: VeilColors.border),
        ),
        title: Text('Could not download the core',
            style: VeilText.display(size: 17, weight: 600)),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(e.message,
                  style: VeilText.ui(
                      size: 12.5, color: VeilColors.text2, height: 1.55)),
              if (e.attempts.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text('TRIED', style: VeilText.label(size: 10)),
                const SizedBox(height: 5),
                for (final a in e.attempts)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 3),
                    child: Text('• $a',
                        style: VeilText.mono(
                            size: 10.5, color: VeilColors.muted, height: 1.4)),
                  ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              _pickCoreFile();
            },
            style: TextButton.styleFrom(foregroundColor: VeilColors.accent),
            child: const Text('Install from a file'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx),
            style: FilledButton.styleFrom(
                backgroundColor: VeilColors.accent,
                foregroundColor: VeilColors.onAccent),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  /// Adopts a binary the user downloaded by hand.
  Future<void> _pickCoreFile() async {
    final exe = CoreManager.exeName(CoreKind.singbox);
    await _editText(
      title: 'Install core from a file',
      hint: Platform.isWindows
          ? r'C:\Users\you\Downloads\sing-box.exe'
          : '/home/you/Downloads/sing-box',
      initial: '',
      helper: 'Download the sing-box release for your platform, unzip it, and '
          'paste the full path to $exe here. Veil copies it into its own '
          'folder so it keeps working if you move the original.',
      onSave: (v) async {
        final path = v.trim();
        if (path.isEmpty) return;
        try {
          final adopted = await CoreManager.adoptBinary(CoreKind.singbox, path);
          await Storage.I.setCorePath(adopted);
          await _loadVersions();
          if (mounted) showVeilToast(context, 'Core installed from file');
        } catch (e) {
          if (mounted) showVeilToast(context, '$e', error: true);
        }
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.state;
    final p = s.profile;
    final wide = MediaQuery.sizeOf(context).width >= 900;

    return SafeArea(
      bottom: false,
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
            16, 10, 16, wide ? 24 : mobileTabBarClearance(context)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Settings', style: VeilText.display(size: 20, weight: 600)),
            const SizedBox(height: 16),

            // ── Account card ───────────────────────────────────────────────
            if (p != null)
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      VeilColors.accent.withValues(alpha: 0.12),
                      VeilColors.upload.withValues(alpha: 0.10),
                    ],
                  ),
                  borderRadius: BorderRadius.circular(VeilRadius.xl),
                  border: Border.all(color: VeilColors.accent.withValues(alpha: 0.20)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 48,
                          height: 48,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: VeilColors.accent.withValues(alpha: 0.20),
                          ),
                          child: Center(
                            child: Text(
                              (p.name.isEmpty ? p.username : p.name)
                                  .characters
                                  .take(2)
                                  .toString()
                                  .toUpperCase(),
                              style: VeilText.display(
                                  size: 16, weight: 600, color: VeilColors.accent),
                            ),
                          ),
                        ),
                        const SizedBox(width: 13),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(p.name.isEmpty ? p.username : p.name,
                                  style: VeilText.ui(size: 15, weight: 600)),
                              const SizedBox(height: 3),
                              Row(
                                children: [
                                  Text(p.username,
                                      style: VeilText.mono(
                                          size: 11.5, color: VeilColors.text2)),
                                  const SizedBox(width: 6),
                                  InkWell(
                                    onTap: () => copyToClipboard(
                                        context, p.username, 'Username copied'),
                                    child: Icon(Icons.copy_rounded,
                                        size: 12, color: VeilColors.muted),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 6),
                              Row(
                                children: [
                                  StatusPill(
                                    label: p.status,
                                    color: p.canConnect
                                        ? VeilColors.accent
                                        : VeilColors.warn,
                                    icon: Icons.verified_user_rounded,
                                  ),
                                  if (p.daysLeft != null) ...[
                                    const SizedBox(width: 8),
                                    Text('${p.daysLeft} days left',
                                        style: VeilText.mono(
                                            size: 11, color: VeilColors.muted)),
                                  ],
                                ],
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    QuotaBar(pct: p.unlimited ? 0 : p.trafficPct),
                    const SizedBox(height: 7),
                    Row(
                      children: [
                        Text(
                          p.unlimited
                              ? 'Unlimited data'
                              : '${p.trafficUsedGb.toStringAsFixed(2)} of ${p.trafficLimitGb.toStringAsFixed(0)} GB used',
                          style: VeilText.ui(size: 11.5, color: VeilColors.text2),
                        ),
                        const Spacer(),
                        if (p.owner != null)
                          Text('via ${p.owner}',
                              style: VeilText.ui(size: 11, color: VeilColors.muted)),
                      ],
                    ),
                    if (p.ipLimit > 0) ...[
                      const SizedBox(height: 9),
                      _DeviceUsage(
                        profile: p,
                        onRelease: (device) => _releaseDevice(device),
                      ),
                    ],
                  ],
                ),
              ),
            const SizedBox(height: 20),

            // Sections flow into as many columns as the window allows, so a
            // desktop window stops being one long strip with empty margins.
            VeilSectionGrid(sections: [
            // ── Connection ─────────────────────────────────────────────────
            VeilSection(
              title: 'Connection',
              children: [
                // Both platforms now. Android's proxy-only mode runs the core
                // without a VpnService, which is the way out when the device
                // refuses the VPN permission or another VPN already holds it.
                VeilListRow(
                  label: 'VPN mode (full tunnel)',
                  sub: _tunnelModeSummary(),
                  icon: Icons.vpn_lock_rounded,
                  trailing: VeilSwitch(
                    value: Storage.I.vpnMode,
                    onChanged: (v) => _setVpnMode(v),
                  ),
                ),
                if (!Storage.I.vpnMode)
                  VeilListRow(
                    label: 'Local proxy address',
                    sub: 'Point an app at this to route it through the tunnel',
                    icon: Icons.lan_rounded,
                    trailing: Text(
                      '127.0.0.1:${Storage.I.socksPort}',
                      style: VeilText.mono(size: 12, color: VeilColors.text2),
                    ),
                    onTap: () => copyToClipboard(
                      context,
                      '127.0.0.1:${Storage.I.socksPort}',
                      'Proxy address copied',
                    ),
                  ),
                VeilListRow(
                  label: 'Detailed connect page',
                  sub: Storage.I.detailedHome
                      ? 'Live map, route and security panel'
                      : 'Simple — one button and the session timer',
                  icon: Icons.dashboard_rounded,
                  trailing: VeilSwitch(
                    value: Storage.I.detailedHome,
                    onChanged: (v) async {
                      await widget.state.setDetailedHome(v);
                      if (mounted) setState(() {});
                    },
                  ),
                ),
                VeilListRow(
                  label: 'Kill switch',
                  sub: Storage.I.killSwitch
                      ? _killSwitchSummary()
                      : 'Off — traffic falls back to the open connection',
                  icon: Icons.block_rounded,
                  trailing: VeilSwitch(
                    value: Storage.I.killSwitch,
                    onChanged: (v) async {
                      await widget.state.setKillSwitch(v);
                      if (mounted) setState(() {});
                    },
                  ),
                ),
                if (Platform.isAndroid)
                  VeilListRow(
                    label: 'System-level kill switch',
                    sub: 'Android can block all traffic outside the VPN — turn '
                        'on "Block connections without VPN"',
                    icon: Icons.settings_ethernet_rounded,
                    trailing: Icon(Icons.open_in_new_rounded,
                        size: 16, color: VeilColors.muted),
                    onTap: _openAndroidVpnSettings,
                  ),
                VeilListRow(
                  label: 'Auto-connect on launch',
                  sub: 'Reconnect to the last used server',
                  icon: Icons.bolt_rounded,
                  trailing: VeilSwitch(
                    value: Storage.I.autoConnect,
                    onChanged: (v) async {
                      await Storage.I.setAutoConnect(v);
                      setState(() {});
                    },
                  ),
                ),
                VeilListRow(
                  label: 'DNS leak guard',
                  sub: 'Every lookup goes through the tunnel, whichever '
                      'resolver an app asks for',
                  icon: Icons.dns_rounded,
                  trailing: VeilSwitch(
                    value: Storage.I.dnsGuard,
                    onChanged: (v) async {
                      await widget.state.setGuard(dns: v);
                      if (mounted) setState(() {});
                      _noteRestart();
                    },
                  ),
                ),
                VeilListRow(
                  label: 'IPv6 leak guard',
                  sub: 'Drops IPv6 instead of letting it slip past a '
                      'v4-only tunnel',
                  icon: Icons.alt_route_rounded,
                  trailing: VeilSwitch(
                    value: Storage.I.ipv6Guard,
                    onChanged: (v) async {
                      await widget.state.setGuard(ipv6: v);
                      if (mounted) setState(() {});
                      _noteRestart();
                    },
                  ),
                ),
                VeilListRow(
                  label: 'WebRTC guard',
                  sub: 'Blocks the STUN discovery that reveals your real '
                      'address',
                  icon: Icons.videocam_off_rounded,
                  trailing: VeilSwitch(
                    value: Storage.I.webRtcGuard,
                    onChanged: (v) async {
                      await widget.state.setGuard(webRtc: v);
                      if (mounted) setState(() {});
                      _noteRestart();
                    },
                  ),
                ),
                VeilListRow(
                  label: 'Timezone guard',
                  sub: 'Warns when your device clock does not match the exit '
                      'country — a leak no VPN can hide for you',
                  icon: Icons.schedule_rounded,
                  trailing: VeilSwitch(
                    value: Storage.I.timezoneGuard,
                    onChanged: (v) async {
                      await widget.state.setGuard(timezone: v);
                      if (mounted) setState(() {});
                    },
                  ),
                ),
                VeilListRow(
                  label: 'Local discovery guard',
                  sub: 'Stops mDNS, LLMNR, SSDP and NetBIOS announcing this '
                      'device by name to the network',
                  icon: Icons.wifi_tethering_off_rounded,
                  trailing: VeilSwitch(
                    value: Storage.I.lanGuard,
                    onChanged: (v) async {
                      await widget.state.setGuard(lan: v);
                      if (mounted) setState(() {});
                      _noteRestart();
                    },
                  ),
                ),
                VeilListRow(
                  label: 'Block QUIC',
                  sub: 'Forces browsers onto TCP. Slower, but nothing slips '
                      'out over UDP the tunnel handles badly',
                  icon: Icons.speed_rounded,
                  trailing: VeilSwitch(
                    value: Storage.I.quicGuard,
                    onChanged: (v) async {
                      await widget.state.setGuard(quic: v);
                      if (mounted) setState(() {});
                      _noteRestart();
                    },
                  ),
                ),
                VeilListRow(
                  label: 'Bypass local network',
                  sub: 'Keep LAN and private IPs off the tunnel',
                  icon: Icons.router_rounded,
                  trailing: VeilSwitch(
                    value: Storage.I.bypassLan,
                    onChanged: (v) async {
                      await Storage.I.setBypassLan(v);
                      setState(() {});
                      _noteRestart();
                    },
                  ),
                ),
                VeilListRow(
                  label: 'Block ads & trackers',
                  sub: 'Drops requests to known ad and tracking hosts',
                  icon: Icons.shield_moon_rounded,
                  showDivider: _isDesktop,
                  trailing: VeilSwitch(
                    value: Storage.I.blockAds,
                    onChanged: (v) async {
                      await Storage.I.setBlockAds(v);
                      setState(() {});
                      _noteRestart();
                    },
                  ),
                ),
                if (_isDesktop)
                  VeilListRow(
                    label: 'Set system proxy',
                    sub: Storage.I.vpnMode
                        ? 'Not used in VPN mode'
                        : 'Point Windows/macOS/GNOME apps at the local proxy',
                    icon: Icons.settings_ethernet_rounded,
                    showDivider: false,
                    trailing: VeilSwitch(
                      value: Storage.I.systemProxy && !Storage.I.vpnMode,
                      onChanged: Storage.I.vpnMode
                          ? (_) {}
                          : (v) async {
                              await Storage.I.setSystemProxy(v);
                              setState(() {});
                              _noteRestart();
                            },
                    ),
                  ),
              ],
            ),

            // ── Network ────────────────────────────────────────────────────
            VeilSection(
              title: 'Network',
              children: [
                VeilListRow(
                  label: 'DNS servers',
                  sub: Storage.I.dnsServers,
                  icon: Icons.dns_rounded,
                  onTap: () => _editText(
                    title: 'DNS servers',
                    hint: '1.1.1.1, 8.8.8.8',
                    initial: Storage.I.dnsServers,
                    onSave: (v) => Storage.I.setDnsServers(v),
                  ),
                  trailing: Icon(Icons.chevron_right_rounded,
                      size: 18, color: VeilColors.muted),
                ),
                VeilListRow(
                  label: 'Local SOCKS port',
                  sub: '${Storage.I.socksPort}',
                  icon: Icons.lan_rounded,
                  onTap: () => _editNumber(
                    title: 'Local SOCKS port',
                    initial: Storage.I.socksPort,
                    onSave: (v) => Storage.I.setSocksPort(v),
                  ),
                  trailing: Icon(Icons.chevron_right_rounded,
                      size: 18, color: VeilColors.muted),
                ),
                VeilListRow(
                  label: 'Local HTTP port',
                  sub: '${Storage.I.httpPort}',
                  icon: Icons.http_rounded,
                  showDivider: Platform.isAndroid,
                  onTap: () => _editNumber(
                    title: 'Local HTTP port',
                    initial: Storage.I.httpPort,
                    onSave: (v) => Storage.I.setHttpPort(v),
                  ),
                  trailing: Icon(Icons.chevron_right_rounded,
                      size: 18, color: VeilColors.muted),
                ),
              ],
            ),

            // ── Routing ────────────────────────────────────────────────────
            VeilSection(
              title: 'Routing',
              children: [
                VeilListRow(
                  label: 'Split tunnelling',
                  sub: _splitSummary(),
                  icon: Icons.call_split_rounded,
                  onTap: () async {
                    await Navigator.of(context).push(MaterialPageRoute<void>(
                      builder: (_) => SplitTunnelScreen(
                          onChanged: () => mounted ? setState(() {}) : null),
                    ));
                    if (mounted) setState(() {});
                    _noteRestart();
                  },
                  trailing: Icon(Icons.chevron_right_rounded,
                      size: 18, color: VeilColors.muted),
                ),
                VeilListRow(
                  label: 'Per-app tunnels',
                  sub: _appTunnelSummary(),
                  icon: Icons.alt_route_rounded,
                  onTap: () async {
                    await Navigator.of(context).push(MaterialPageRoute<void>(
                      builder: (_) => AppTunnelsScreen(
                        state: widget.state,
                        onChanged: () => mounted ? setState(() {}) : null,
                      ),
                    ));
                    if (mounted) setState(() {});
                  },
                  trailing: Icon(Icons.chevron_right_rounded,
                      size: 18, color: VeilColors.muted),
                ),
                VeilListRow(
                  label: 'Domain & IP rules',
                  sub: _rulesSummary(),
                  icon: Icons.alt_route_rounded,
                  showDivider: false,
                  onTap: () async {
                    await Navigator.of(context).push(MaterialPageRoute<void>(
                      builder: (_) => RoutingRulesScreen(
                          onChanged: () => mounted ? setState(() {}) : null),
                    ));
                    if (mounted) setState(() {});
                    _noteRestart();
                  },
                  trailing: Icon(Icons.chevron_right_rounded,
                      size: 18, color: VeilColors.muted),
                ),
              ],
            ),

            // ── Appearance ─────────────────────────────────────────────────
            VeilSection(
              title: 'Appearance',
              children: [
                VeilListRow(
                  label: 'Theme',
                  sub: _themeSummary(),
                  icon: s.themeMode.icon,
                  showDivider: false,
                  trailing: _ThemePicker(
                    value: s.themeMode,
                    onChanged: (m) async {
                      await s.setThemeMode(m);
                      if (mounted) setState(() {});
                    },
                  ),
                ),
              ],
            ),

            // ── Window (desktop) ───────────────────────────────────────────
            if (_isDesktop)
              VeilSection(
                title: 'Window',
                children: [
                  VeilListRow(
                    label: Platform.isWindows
                        ? 'Start with Windows'
                        : Platform.isMacOS
                            ? 'Open at login'
                            : 'Start on login',
                    sub: s.launchAtLogin
                        ? 'Launches when you sign in'
                        : 'Only starts when you open it',
                    icon: Icons.power_settings_new_rounded,
                    trailing: VeilSwitch(
                      value: s.launchAtLogin,
                      onChanged: (v) => _setLaunchAtLogin(v),
                    ),
                  ),
                  VeilListRow(
                    label: 'Close to tray',
                    sub: Storage.I.closeToTray
                        ? 'The close button hides Veil in the system tray'
                        : 'The close button quits Veil',
                    icon: Icons.dock_rounded,
                    trailing: VeilSwitch(
                      value: Storage.I.closeToTray,
                      onChanged: (v) async {
                        await Storage.I.setCloseToTray(v);
                        setState(() {});
                      },
                    ),
                  ),
                  VeilListRow(
                    label: 'Start minimised',
                    // Only means anything alongside the setting above, so it
                    // says which one it depends on rather than looking broken
                    // when nothing happens.
                    sub: s.launchAtLogin
                        ? 'Open straight to the tray on launch'
                        : 'Open straight to the tray — including at sign-in, '
                            'once "Start with Windows" is on',
                    icon: Icons.visibility_off_rounded,
                    showDivider: false,
                    trailing: VeilSwitch(
                      value: Storage.I.startMinimised,
                      onChanged: (v) async {
                        await Storage.I.setStartMinimised(v);
                        setState(() {});
                      },
                    ),
                  ),
                ],
              ),

            // ── Core (desktop) ─────────────────────────────────────────────
            if (_isDesktop)
              VeilSection(
                title: 'Tunnel core',
                children: [
                  VeilListRow(
                    label: 'Installed core',
                    sub: _coreVersion.isEmpty
                        ? 'sing-box is not installed yet'
                        : _coreVersion,
                    icon: Icons.memory_rounded,
                    trailing: _installingCore
                        ? SizedBox(
                            width: 110,
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                LinearProgressIndicator(
                                  value: _installProgress,
                                  minHeight: 3,
                                  backgroundColor:
                                      VeilColors.tint(0.08),
                                  valueColor: AlwaysStoppedAnimation(
                                      VeilColors.accent),
                                ),
                                const SizedBox(height: 4),
                                Text(_installNote,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: VeilText.ui(
                                        size: 9, color: VeilColors.muted)),
                              ],
                            ),
                          )
                        : TextButton(
                            onPressed: _installCore,
                            style: TextButton.styleFrom(
                                foregroundColor: VeilColors.accent),
                            child: Text(
                                _coreVersion.isEmpty ? 'Download' : 'Update',
                                style: VeilText.ui(
                                    size: 12.5,
                                    weight: 600,
                                    color: VeilColors.accent)),
                          ),
                  ),
                  VeilListRow(
                    label: 'Install from a file',
                    sub: 'Pick a sing-box binary you downloaded yourself',
                    icon: Icons.drive_folder_upload_rounded,
                    onTap: _pickCoreFile,
                    trailing: Icon(Icons.chevron_right_rounded,
                        size: 18, color: VeilColors.muted),
                  ),
                  VeilListRow(
                    label: 'Custom core path',
                    sub: Storage.I.corePath.isEmpty
                        ? 'Use the managed copy'
                        : Storage.I.corePath,
                    icon: Icons.folder_open_rounded,
                    showDivider: false,
                    onTap: () => _editText(
                      title: 'Path to the sing-box executable',
                      hint: CoreManager.exeName(CoreKind.singbox),
                      initial: Storage.I.corePath,
                      helper: 'Leave empty to use the copy Veil manages itself.',
                      onSave: (v) async {
                        await Storage.I.setCorePath(v.trim());
                        await _loadVersions();
                      },
                    ),
                    trailing: Icon(Icons.chevron_right_rounded,
                        size: 18, color: VeilColors.muted),
                  ),
                ],
              ),

            // ── Account actions ────────────────────────────────────────────
            VeilSection(
              title: 'Account',
              children: [
                VeilListRow(
                  label: 'Panel address',
                  sub: Storage.I.baseUrl,
                  icon: Icons.dns_outlined,
                  trailing: IconButton(
                    onPressed: () =>
                        copyToClipboard(context, Storage.I.baseUrl, 'Address copied'),
                    icon: const Icon(Icons.copy_rounded, size: 15),
                    color: VeilColors.muted,
                  ),
                ),
                if (p != null && p.subUrl.isNotEmpty)
                  VeilListRow(
                    label: 'Subscription link',
                    sub: 'For importing into other VPN clients',
                    icon: Icons.link_rounded,
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          onPressed: () => copyToClipboard(
                              context, p.subUrl, 'Subscription link copied'),
                          icon: const Icon(Icons.copy_rounded, size: 15),
                          color: VeilColors.muted,
                        ),
                        IconButton(
                          onPressed: () => launchUrl(Uri.parse(p.subUrl),
                              mode: LaunchMode.externalApplication),
                          icon: const Icon(Icons.open_in_new_rounded, size: 15),
                          color: VeilColors.muted,
                        ),
                      ],
                    ),
                  ),
                VeilListRow(
                  label: 'Refresh account',
                  // A blocked account is handed no configs, so "0 cached" was
                  // all this said about being over the device limit.
                  sub: s.blockedReason ??
                      '${s.servers.length} configuration(s) cached',
                  icon: Icons.refresh_rounded,
                  onTap: () async {
                    await s.refresh();
                    if (!context.mounted) return;
                    // Refreshing is how someone gets out of a blocked state, so
                    // it has to say whether it worked.
                    showVeilToast(
                      context,
                      s.blockedReason ??
                          'Account refreshed — ${s.servers.length} location(s)',
                      error: s.blockedReason != null,
                    );
                  },
                ),
                VeilListRow(
                  label: 'Sign out',
                  sub: 'Disconnects and forgets this device',
                  icon: Icons.logout_rounded,
                  showDivider: false,
                  onTap: () async {
                    final ok = await _confirm('Sign out?',
                        'You will need your username and password to sign back in.');
                    if (ok) await s.logout();
                  },
                  trailing: Icon(Icons.chevron_right_rounded,
                      size: 18, color: VeilColors.danger),
                ),
              ],
            ),

            // ── Updates ────────────────────────────────────────────────────
            // The Play build does not check, because it may not act on the
            // answer. Saying where updates come from is more use than a
            // "check now" button that can only ever report.
            if (!kSelfUpdate)
              VeilSection(
                title: 'Updates',
                children: [
                  VeilListRow(
                    label: 'Updates come from Google Play',
                    sub: _appVersion.isEmpty
                        ? 'Play installs new versions for you.'
                        : 'Version $_appVersion. Play installs new versions '
                            'for you.',
                    icon: Icons.verified_rounded,
                    showDivider: false,
                  ),
                ],
              )
            else
            VeilSection(
              title: 'Updates',
              children: [
                VeilListRow(
                  label: s.update.available
                      ? 'Version ${s.update.latest} is available'
                      : 'You are up to date',
                  sub: s.update.available
                      ? (s.update.notes.isEmpty
                          ? (s.update.installable
                              ? 'Tap to download and install it'
                              : 'Tap to open the download page')
                          : s.update.notes)
                      : (s.update.latest.isEmpty
                          ? 'Your provider has not published a version yet'
                          : 'Version ${s.update.current} — '
                              'latest published: ${s.update.latest}'),
                  icon: s.update.available
                      ? Icons.system_update_alt_rounded
                      : Icons.verified_rounded,
                  showDivider: true,
                  onTap: !s.update.available
                      ? null
                      : s.update.installable
                          ? _installUpdate
                          : (s.update.url.isEmpty
                              ? null
                              : () => launchUrl(Uri.parse(s.update.url),
                                  mode: LaunchMode.externalApplication)),
                  trailing: s.updateProgress != null
                      ? SizedBox(
                          width: 110,
                          child: LinearProgressIndicator(
                            value: s.updateProgress! > 0 ? s.updateProgress : null,
                            minHeight: 3,
                            backgroundColor: VeilColors.tint(0.08),
                            valueColor:
                                AlwaysStoppedAnimation(VeilColors.accent),
                          ),
                        )
                      : s.update.available
                          ? Icon(Icons.download_rounded,
                              size: 18, color: VeilColors.accent)
                          : null,
                ),
                VeilListRow(
                  label: 'Check now',
                  sub: 'Asks your provider\'s panel for the latest build',
                  icon: Icons.refresh_rounded,
                  showDivider: false,
                  onTap: () async {
                    await s.checkForUpdate();
                    if (!context.mounted) return;
                    showVeilToast(
                      context,
                      s.update.available
                          ? 'Version ${s.update.latest} is available'
                          : 'You are running the latest version',
                    );
                  },
                  trailing: Icon(Icons.chevron_right_rounded,
                      size: 18, color: VeilColors.muted),
                ),
              ],
            ),

            // ── About ──────────────────────────────────────────────────────
            VeilSection(
              title: 'About',
              children: [
                VeilListRow(
                  label: 'Veil client',
                  sub: _appVersion.isEmpty ? '…' : 'Version $_appVersion',
                  icon: Icons.info_outline_rounded,
                  showDivider: false,
                  trailing: Text(
                    Platform.operatingSystem,
                    style: VeilText.mono(size: 11, color: VeilColors.muted),
                  ),
                ),
              ],
            ),
            ]),
          ],
        ),
      ),
    );
  }

  String _killSwitchSummary() {
    if (Platform.isAndroid) {
      return 'Reconnects on a drop; the tunnel blackholes traffic meanwhile';
    }
    return Storage.I.vpnMode
        ? 'Blocks traffic if the tunnel drops, then reconnects'
        : 'Holds the system proxy closed if the tunnel drops';
  }

  /// Android's own kill switch lives in system settings and cannot be toggled
  /// by an app — the best we can do is take the user there.
  Future<void> _openAndroidVpnSettings() async {
    try {
      await const MethodChannel('app.veil/installed_apps')
          .invokeMethod<void>('openVpnSettings');
    } on PlatformException catch (e) {
      if (mounted) {
        showVeilToast(context, e.message ?? 'Could not open VPN settings',
            error: true);
      }
    }
  }

  String _appTunnelSummary() {
    if (!widget.state.supportsAppTunnels) return 'Desktop only';
    final all = widget.state.appBindings;
    if (all.isEmpty) return 'Give individual apps their own location';
    final on = all.where((b) => b.enabled).length;
    return '${all.length} app${all.length == 1 ? '' : 's'} bound · $on running';
  }

  String _splitSummary() {
    final mode = Storage.I.splitMode;
    final n = Storage.I.splitApps.length;
    if (mode == SplitMode.all || n == 0) return 'Everything uses the tunnel';
    return '${mode.label} · $n app(s)';
  }

  String _rulesSummary() {
    final t = Storage.I.tunnelRules.length;
    final b = Storage.I.bypassRules.length;
    if (t == 0 && b == 0) return 'No custom domain or IP rules';
    return '$t forced through · $b bypassing';
  }

  /// Turning VPN mode on needs elevation; offer to restart elevated rather
  /// than letting the connect attempt fail later.
  String _tunnelModeSummary() {
    if (Storage.I.vpnMode) {
      return Platform.isAndroid
          ? 'Every app is routed through the tunnel'
          : 'Every app is routed · needs administrator rights';
    }
    return Platform.isAndroid
        ? 'Proxy only — no VPN permission needed, but nothing is routed '
            'until an app is pointed at the local port'
        : 'Off — only apps that honour the system proxy';
  }

  Future<void> _setVpnMode(bool v) async {
    await Storage.I.setVpnMode(v);
    if (!mounted) return;
    setState(() {});
    // Android needs no elevation either way; the switch is the whole story.
    if (Platform.isAndroid) {
      _noteRestart();
      return;
    }
    if (!v) {
      _noteRestart();
      return;
    }
    if (Elevation.isElevated) {
      _noteRestart();
      return;
    }
    final restart = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: VeilColors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(VeilRadius.lg),
          side: BorderSide(color: VeilColors.border),
        ),
        title: Text('Restart with administrator rights?',
            style: VeilText.display(size: 17, weight: 600)),
        content: Text(
          'VPN mode creates a network device, which needs administrator '
          'rights. $kAppName can restart itself now — you will see a Windows '
          'permission prompt.',
          style: VeilText.ui(size: 13, color: VeilColors.text2, height: 1.55),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            style: TextButton.styleFrom(foregroundColor: VeilColors.muted),
            child: const Text('Later'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(
                backgroundColor: VeilColors.accent,
                foregroundColor: VeilColors.onAccent),
            child: const Text('Restart now'),
          ),
        ],
      ),
    );
    if (restart != true) {
      if (mounted) {
        showVeilToast(context,
            'VPN mode will not work until you restart. ${Elevation.manualInstruction}');
      }
      return;
    }
    await widget.state.shutdown();
    final ok = await Elevation.relaunchElevated();
    if (ok) {
      exit(0);
    } else if (mounted) {
      showVeilToast(context, Elevation.manualInstruction, error: true);
    }
  }

  String _themeSummary() {
    switch (widget.state.themeMode) {
      case AppThemeMode.system:
        return VeilTheme.isDark
            ? 'Following the system — currently dark'
            : 'Following the system — currently light';
      case AppThemeMode.light:
        return 'Always light, whatever the system is set to';
      case AppThemeMode.dark:
        return 'Always dark, whatever the system is set to';
    }
  }

  Future<void> _setLaunchAtLogin(bool v) async {
    final error = await widget.state.setLaunchAtLogin(v);
    if (!mounted) return;
    setState(() {});
    if (error != null) showVeilToast(context, error, error: true);
  }

  /// Hands one of the account's device slots back to the panel.
  Future<void> _releaseDevice(ClientDevice device) async {
    final name = device.name.isEmpty ? 'that device' : device.name;
    if (!await _confirm('Sign $name out?',
        'It frees the slot straight away. That device will have to sign in '
        'again to connect.')) {
      return;
    }
    final error = await widget.state.releaseDevice(device.id);
    if (!mounted) return;
    setState(() {});
    showVeilToast(context, error ?? '$name signed out', error: error != null);
  }

  /// Downloads the published build and hands it to the platform installer.
  ///
  /// The progress bar is driven off [AppState.updateProgress], so this only has
  /// to keep the row rebuilding and deal with the two endings.
  Future<void> _installUpdate() async {
    void repaint() {
      if (mounted) setState(() {});
    }

    widget.state.addListener(repaint);
    bool quit;
    try {
      quit = await widget.state.installUpdate();
    } finally {
      widget.state.removeListener(repaint);
      repaint();
    }
    if (quit) {
      await widget.state.shutdown();
      exit(0);
    }
    if (mounted && widget.state.updateError != null) {
      showVeilToast(context, widget.state.updateError!, error: true);
    }
  }

  void _noteRestart() {
    if (widget.state.isConnected) {
      showVeilToast(context, 'Reconnect for this to take effect');
    }
  }

  Future<bool> _confirm(String title, String message) async {
    final r = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: VeilColors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(VeilRadius.lg),
          side: BorderSide(color: VeilColors.border),
        ),
        title: Text(title, style: VeilText.display(size: 17, weight: 600)),
        content: Text(message,
            style: VeilText.ui(size: 13, color: VeilColors.text2, height: 1.5)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            style: TextButton.styleFrom(foregroundColor: VeilColors.muted),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(
                backgroundColor: VeilColors.danger,
                foregroundColor: Colors.white),
            child: const Text('Confirm'),
          ),
        ],
      ),
    );
    return r ?? false;
  }

  Future<void> _editText({
    required String title,
    required String hint,
    required String initial,
    String? helper,
    required Future<void> Function(String) onSave,
  }) async {
    final value = await promptForText(
      context,
      title: title,
      hint: hint,
      initial: initial,
      helper: helper,
    );
    if (value == null) return;
    await onSave(value);
    if (mounted) setState(() {});
  }

  Future<void> _editNumber({
    required String title,
    required int initial,
    required Future<void> Function(int) onSave,
  }) async {
    final value = await promptForText(
      context,
      title: title,
      initial: '$initial',
      numeric: true,
    );
    if (value == null || !mounted) return;

    final port = int.tryParse(value);
    if (port == null || port < 1 || port > 65535) {
      showVeilToast(context, 'Enter a port between 1 and 65535', error: true);
      return;
    }
    await onSave(port);
    if (!mounted) return;
    setState(() {});
    _noteRestart();
  }
}

/// System / Light / Dark, as three segments rather than a switch.
///
/// A two-state toggle cannot express "follow the system", and that is the one
/// most people want — the app should go light with the rest of the machine at
/// sunrise without anybody touching it.
class _ThemePicker extends StatelessWidget {
  const _ThemePicker({required this.value, required this.onChanged});

  final AppThemeMode value;
  final ValueChanged<AppThemeMode> onChanged;

  @override
  Widget build(BuildContext context) {
    Widget segment(AppThemeMode mode) {
      final on = mode == value;
      return Tooltip(
        message: mode.label,
        child: Clickable(enabled: !on, child: GestureDetector(
          onTap: on ? null : () => onChanged(mode),
          behavior: HitTestBehavior.opaque,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: on ? VeilColors.accentTint : Colors.transparent,
              borderRadius: BorderRadius.circular(VeilRadius.pill),
            ),
            child: Icon(mode.icon,
                size: 15, color: on ? VeilColors.accent : VeilColors.muted),
          ),
        )),
      );
    }

    return Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: VeilColors.surface2,
        border: Border.all(color: VeilColors.borderSoft),
        borderRadius: BorderRadius.circular(VeilRadius.pill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [for (final m in AppThemeMode.values) segment(m)],
      ),
    );
  }
}

/// "Devices 2 of 3", with the slots the panel currently counts.
///
/// The limit is enforced by the panel — this explains it, and lets a slot be
/// handed back from here. That last part matters more than it sounds: a slot is
/// only released when the device holding it signs out or goes quiet, so someone
/// whose laptop is at the office had no way to use their phone until it aged
/// out.
class _DeviceUsage extends StatelessWidget {
  const _DeviceUsage({required this.profile, this.onRelease});

  final Profile profile;
  final Future<void> Function(ClientDevice device)? onRelease;

  @override
  Widget build(BuildContext context) {
    final used = profile.devicesInUse;
    final limit = profile.ipLimit;
    final full = profile.atDeviceLimit;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Icon(Icons.devices_rounded,
                size: 14,
                color: full ? VeilColors.warn : VeilColors.muted),
            const SizedBox(width: 7),
            Text(
              used == null
                  ? 'Up to $limit device${limit == 1 ? '' : 's'} at a time'
                  : 'Devices $used of $limit',
              style: VeilText.ui(
                  size: 11.5,
                  weight: 500,
                  color: full ? VeilColors.warn : VeilColors.text2),
            ),
          ],
        ),
        if (profile.devices.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 5, left: 21),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final d in profile.devices)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 2),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            [
                              d.name.isEmpty ? 'Unknown device' : d.name,
                              if (d.platform.isNotEmpty) d.platform,
                            ].join(' · '),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: VeilText.ui(
                                size: 10.5, color: VeilColors.muted),
                          ),
                        ),
                        if (onRelease != null)
                          Clickable(child: GestureDetector(
                            onTap: () => onRelease!(d),
                            behavior: HitTestBehavior.opaque,
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 6, vertical: 2),
                              child: Text('Sign out',
                                  style: VeilText.ui(
                                      size: 10.5,
                                      weight: 600,
                                      color: VeilColors.accent)),
                            ),
                          )),
                      ],
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}
