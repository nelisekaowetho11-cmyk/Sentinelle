import 'dart:io';

import 'package:flutter/material.dart';

import '../models/app_binding.dart';
import '../models/models.dart';
import '../services/app_list.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../widgets/common.dart';

/// Pin individual applications to locations of their own — config1 for app1,
/// config2 for app2 — and run them at the same time.
///
/// The apps share a single core rather than each getting a tunnel of its own.
/// That is a hard constraint, not a design choice: the machine has one routing
/// table and one TUN device, so two independent tunnels would fight over both.
/// sing-box resolves the process behind every connection and sends it to that
/// app's outbound, which produces the same result — several destinations live
/// at once — with none of the conflict.
class AppTunnelsScreen extends StatefulWidget {
  const AppTunnelsScreen({super.key, required this.state, this.onChanged});

  final AppState state;
  final VoidCallback? onChanged;

  @override
  State<AppTunnelsScreen> createState() => _AppTunnelsScreenState();
}

class _AppTunnelsScreenState extends State<AppTunnelsScreen> {
  final Set<String> _selected = {};
  List<AppEntry> _running = const [];
  bool _loading = false;

  AppState get _state => widget.state;
  List<AppBinding> get _bindings => _state.appBindings;

  @override
  void initState() {
    super.initState();
    if (AppList.supported) _loadRunning();
  }

  Future<void> _loadRunning() async {
    setState(() => _loading = true);
    final apps = await AppList.running();
    if (!mounted) return;
    setState(() {
      _running = apps;
      _loading = false;
    });
  }

  void _changed() {
    if (mounted) setState(() {});
    widget.onChanged?.call();
  }

  @override
  Widget build(BuildContext context) {
    final supported = _state.supportsAppTunnels;

    return Scaffold(
      backgroundColor: VeilColors.bg,
      appBar: AppBar(
        backgroundColor: VeilColors.surface,
        title: Text('Per-app tunnels',
            style: VeilText.display(size: 16, weight: 600)),
        actions: [
          if (_bindings.any((b) => b.enabled))
            TextButton(
              onPressed: () async {
                await _state.stopAllBindings();
                _changed();
              },
              child: Text('Stop all',
                  style: VeilText.ui(size: 12.5, color: VeilColors.danger)),
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 28),
        children: [
          if (!supported) _androidNote() else _explainer(),
          const SizedBox(height: 16),
          if (_bindings.isEmpty)
            _empty()
          else
            VeilSection(
              title: 'App tunnels',
              children: [
                for (var i = 0; i < _bindings.length; i++)
                  _bindingRow(_bindings[i], last: i == _bindings.length - 1),
              ],
            ),
          if (_selected.isNotEmpty) _selectionBar(),
          const SizedBox(height: 6),
          SizedBox(
            height: 44,
            child: OutlinedButton.icon(
              onPressed: _state.servers.isEmpty ? null : _addBinding,
              icon: const Icon(Icons.add_rounded, size: 17),
              label: Text('Bind an app to a location',
                  style: VeilText.ui(size: 13, weight: 500)),
              style: OutlinedButton.styleFrom(
                foregroundColor: VeilColors.text,
                side: BorderSide(color: VeilColors.border),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(VeilRadius.md)),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _explainer() => _InfoBox(
        icon: Icons.info_outline_rounded,
        text: 'Each app listed here uses its own location. Everything else '
            'uses the main connection.\n\n'
            'They all run through one core, so changing a binding restarts '
            'the tunnel briefly. Matching is by executable name '
            '(${Platform.isWindows ? 'chrome.exe' : 'firefox'}), and it works '
            'best in VPN mode — in proxy mode only apps that honour the '
            'system proxy can be routed.',
      );

  Widget _androidNote() => _InfoBox(
        icon: Icons.phonelink_off_rounded,
        danger: true,
        text: 'Per-app tunnels are not possible on Android.\n\n'
            'VpnService hands the core raw packets with no record of which app '
            'sent them, and Xray cannot route on app identity — so a second '
            'location cannot be applied to a second app. Android can only '
            'include or exclude whole apps from the one tunnel, which is what '
            'Split tunnelling does.',
      );

  Widget _empty() => _InfoBox(
        icon: Icons.apps_rounded,
        text: 'No apps are bound yet. Pick one below and choose where its '
            'traffic should come out.',
      );

  Widget _bindingRow(AppBinding b, {required bool last}) {
    final server = _serverFor(b);
    final ticked = _selected.contains(b.id);

    return VeilListRow(
      label: b.displayLabel,
      sub: server == null
          ? 'Location no longer available — pick another'
          : '→ ${server.displayName}',
      icon: ticked
          ? Icons.check_box_rounded
          : (b.enabled ? Icons.play_circle_rounded : Icons.pause_circle_rounded),
      showDivider: !last,
      onTap: () => setState(() {
        ticked ? _selected.remove(b.id) : _selected.add(b.id);
      }),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Changing where an app comes out was previously only possible by
          // deleting the binding and making it again, which also threw away
          // whether it had been stopped.
          IconButton(
            tooltip: 'Change location',
            onPressed: () => _editBinding(b),
            icon: const Icon(Icons.edit_location_alt_rounded, size: 16),
            color: VeilColors.text2,
          ),
          VeilSwitch(
            value: b.enabled && server != null,
            onChanged: server == null
                ? (_) {}
                : (v) async {
                    await _state.setBindingEnabled(b.id, v);
                    _changed();
                  },
          ),
          IconButton(
            tooltip: 'Remove',
            onPressed: () async {
              await _state.removeBindings([b.id]);
              _selected.remove(b.id);
              _changed();
            },
            icon: const Icon(Icons.close_rounded, size: 16),
            color: VeilColors.danger,
          ),
        ],
      ),
    );
  }

  /// Repoints an existing binding at another location.
  Future<void> _editBinding(AppBinding b) async {
    final server = await _pickServer(
      title: 'Where should ${b.displayLabel} come out?',
      current: _serverFor(b),
    );
    if (server == null) return;
    await _state.setBindingServer(b.id, server);
    _changed();
  }

  ServerConfig? _serverFor(AppBinding b) {
    for (final s in _state.servers) {
      if (s.uid == b.serverUid) return s;
    }
    return null;
  }

  Widget _selectionBar() => Padding(
        padding: const EdgeInsets.only(top: 12),
        child: Container(
          padding: const EdgeInsets.fromLTRB(13, 9, 9, 9),
          decoration: BoxDecoration(
            color: VeilColors.surface2,
            border: Border.all(color: VeilColors.border),
            borderRadius: BorderRadius.circular(VeilRadius.md),
          ),
          child: Row(
            children: [
              Text('${_selected.length} selected',
                  style: VeilText.ui(size: 12.5, weight: 600)),
              const Spacer(),
              TextButton(
                onPressed: () => setState(_selected.clear),
                child: Text('Cancel',
                    style: VeilText.ui(size: 12.5, color: VeilColors.muted)),
              ),
              TextButton(
                onPressed: () async {
                  await _state.stopBindings(_selected.toList());
                  setState(_selected.clear);
                  _changed();
                },
                child: Text('Stop selected',
                    style: VeilText.ui(
                        size: 12.5, weight: 600, color: VeilColors.danger)),
              ),
            ],
          ),
        ),
      );

  // ── Adding ─────────────────────────────────────────────────────────────────

  Future<void> _addBinding() async {
    final app = await _pickApp();
    if (app == null || !mounted) return;
    final server = await _pickServer(
      title: 'Where should ${app.label} come out?',
    );
    if (server == null) return;
    await _state.addBinding(app.executable, server, label: app.label);
    _changed();
  }

  Future<AppEntry?> _pickApp() {
    // Doubles as the manual entry field: on a machine with a hundred processes
    // scrolling to find one is hopeless, and an app that is not running yet
    // does not appear in the list at all — so whatever is typed here either
    // narrows the list or *is* the answer.
    final query = TextEditingController();

    return showModalBottomSheet<AppEntry>(
      context: context,
      isScrollControlled: true,
      backgroundColor: VeilColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding:
              EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(sheetContext).bottom),
          child: StatefulBuilder(
            builder: (context, setSheetState) {
              final needle = query.text.trim().toLowerCase();
              final matches = needle.isEmpty
                  ? _running
                  : _running
                      .where((a) =>
                          a.label.toLowerCase().contains(needle) ||
                          a.executable.toLowerCase().contains(needle))
                      .toList();
              final exact = matches.any(
                  (a) => a.executable.toLowerCase() == needle && needle.isNotEmpty);

              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                    child: Row(
                      children: [
                        Text('Choose an app',
                            style: VeilText.display(size: 15, weight: 600)),
                        const Spacer(),
                        if (_loading)
                          const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2))
                        else
                          IconButton(
                            tooltip: 'Refresh the list',
                            onPressed: () async {
                              await _loadRunning();
                              setSheetState(() {});
                            },
                            icon: const Icon(Icons.refresh_rounded, size: 17),
                            color: VeilColors.text2,
                          ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
                    child: TextField(
                      controller: query,
                      autofocus: true,
                      style: VeilText.mono(size: 12.5),
                      onChanged: (_) => setSheetState(() {}),
                      onSubmitted: (v) {
                        final name = v.trim();
                        if (name.isEmpty) return;
                        Navigator.pop(context, AppEntry(executable: name));
                      },
                      decoration: InputDecoration(
                        isDense: true,
                        prefixIcon: Icon(Icons.search_rounded,
                            size: 17, color: VeilColors.muted),
                        suffixIcon: query.text.isEmpty
                            ? null
                            : IconButton(
                                tooltip: 'Clear',
                                onPressed: () {
                                  query.clear();
                                  setSheetState(() {});
                                },
                                icon: const Icon(Icons.close_rounded, size: 15),
                                color: VeilColors.muted,
                              ),
                        hintText: Platform.isAndroid
                            ? 'Search apps'
                            : 'Search, or type ${Platform.isWindows ? 'chrome.exe' : 'firefox'}',
                      ),
                    ),
                  ),
                  // The typed name is only offered when the list does not
                  // already contain it, so the same app is never on screen
                  // twice.
                  if (needle.isNotEmpty && !exact)
                    ListTile(
                      dense: true,
                      leading: Icon(Icons.add_rounded,
                          size: 17, color: VeilColors.accent),
                      title: Text('Use “${query.text.trim()}”',
                          style: VeilText.ui(
                              size: 13, weight: 600, color: VeilColors.accent)),
                      subtitle: Text(
                          Platform.isAndroid
                              ? 'As a package name'
                              : 'As an executable name — it does not have to be running',
                          style: VeilText.ui(size: 10.5, color: VeilColors.muted)),
                      onTap: () => Navigator.pop(
                          context, AppEntry(executable: query.text.trim())),
                    ),
                  Flexible(
                    child: matches.isEmpty
                        ? Padding(
                            padding: const EdgeInsets.fromLTRB(16, 18, 16, 24),
                            child: Text(
                              _loading
                                  ? 'Looking for running apps…'
                                  : 'Nothing matches that. Type the exact name '
                                      'and use it anyway.',
                              style: VeilText.ui(
                                  size: 12, color: VeilColors.muted, height: 1.5),
                            ),
                          )
                        : ListView.builder(
                            shrinkWrap: true,
                            itemCount: matches.length,
                            itemBuilder: (context, i) {
                              final a = matches[i];
                              return ListTile(
                                dense: true,
                                title: Text(a.label,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: VeilText.ui(size: 13)),
                                subtitle: Text(a.executable,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: VeilText.mono(
                                        size: 10.5, color: VeilColors.muted)),
                                onTap: () => Navigator.pop(context, a),
                              );
                            },
                          ),
                  ),
                  const SizedBox(height: 8),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Future<ServerConfig?> _pickServer({
    required String title,
    ServerConfig? current,
  }) {
    final query = TextEditingController();

    return showModalBottomSheet<ServerConfig>(
      context: context,
      isScrollControlled: true,
      backgroundColor: VeilColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding:
              EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(sheetContext).bottom),
          child: StatefulBuilder(
            builder: (context, setSheetState) {
              final needle = query.text.trim().toLowerCase();
              final matches = needle.isEmpty
                  ? _state.servers
                  : _state.servers
                      .where((s) =>
                          s.displayName.toLowerCase().contains(needle) ||
                          s.displayLocation.toLowerCase().contains(needle) ||
                          s.country.toLowerCase().contains(needle) ||
                          s.address.toLowerCase().contains(needle))
                      .toList();

              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(title,
                          style: VeilText.display(size: 15, weight: 600)),
                    ),
                  ),
                  if (_state.servers.length > 6)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
                      child: TextField(
                        controller: query,
                        style: VeilText.ui(size: 13),
                        onChanged: (_) => setSheetState(() {}),
                        decoration: InputDecoration(
                          isDense: true,
                          prefixIcon: Icon(Icons.search_rounded,
                              size: 17, color: VeilColors.muted),
                          hintText: 'Search locations',
                        ),
                      ),
                    ),
                  Flexible(
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: matches.length,
                      itemBuilder: (context, i) {
                        final s = matches[i];
                        final isCurrent = current != null && s.uid == current.uid;
                        return ListTile(
                          dense: true,
                          selected: isCurrent,
                          leading: Text(
                            s.country.isEmpty ? '—' : s.country.toUpperCase(),
                            style: VeilText.mono(size: 11, weight: 600),
                          ),
                          title: Text(s.displayName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: VeilText.ui(
                                  size: 13,
                                  weight: isCurrent ? 600 : 400,
                                  color: isCurrent
                                      ? VeilColors.accent
                                      : VeilColors.text)),
                          subtitle: Text(s.address,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: VeilText.mono(
                                  size: 10.5, color: VeilColors.muted)),
                          trailing: isCurrent
                              ? Icon(Icons.check_rounded,
                                  size: 16, color: VeilColors.accent)
                              : null,
                          onTap: () => Navigator.pop(context, s),
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: 8),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class _InfoBox extends StatelessWidget {
  const _InfoBox({
    required this.icon,
    required this.text,
    this.danger = false,
  });

  final IconData icon;
  final String text;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final colour = danger ? VeilColors.warn : VeilColors.muted;
    return Container(
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: colour.withValues(alpha: 0.08),
        border: Border.all(color: colour.withValues(alpha: 0.25)),
        borderRadius: BorderRadius.circular(VeilRadius.md),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: colour),
          const SizedBox(width: 10),
          Expanded(
            child: Text(text,
                style: VeilText.ui(
                    size: 11.5, color: VeilColors.text2, height: 1.55)),
          ),
        ],
      ),
    );
  }
}
