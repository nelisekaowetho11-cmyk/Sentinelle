import 'dart:io';

import 'package:flutter/material.dart';

import '../services/app_list.dart';
import '../services/routing.dart';
import '../services/storage.dart';
import '../theme.dart';
import '../widgets/common.dart';

/// Choose which applications use the tunnel.
class SplitTunnelScreen extends StatefulWidget {
  const SplitTunnelScreen({super.key, this.onChanged});
  final VoidCallback? onChanged;

  @override
  State<SplitTunnelScreen> createState() => _SplitTunnelScreenState();
}

class _SplitTunnelScreenState extends State<SplitTunnelScreen> {
  late SplitMode _mode = Storage.I.splitMode;
  late final List<String> _apps = [...Storage.I.splitApps];
  List<AppEntry> _running = const [];
  bool _loading = false;
  final _appSearch = TextEditingController();

  @override
  void dispose() {
    _appSearch.dispose();
    super.dispose();
  }

  List<AppEntry> get _visibleApps {
    final q = _appSearch.text.trim().toLowerCase();
    if (q.isEmpty) return _running;
    return _running
        .where((a) =>
            a.label.toLowerCase().contains(q) ||
            a.executable.toLowerCase().contains(q))
        .toList();
  }

  @override
  void initState() {
    super.initState();
    if (AppList.supported) _loadRunning();
  }

  Future<void> _loadRunning() async {
    setState(() => _loading = true);
    final list = await AppList.running();
    if (!mounted) return;
    setState(() {
      _running = list;
      _loading = false;
    });
  }

  Future<void> _save() async {
    await Storage.I.setSplitMode(_mode);
    await Storage.I.setSplitApps(_apps);
    widget.onChanged?.call();
    if (mounted) setState(() {});
  }

  void _toggle(String exe) {
    setState(() {
      if (_apps.any((a) => a.toLowerCase() == exe.toLowerCase())) {
        _apps.removeWhere((a) => a.toLowerCase() == exe.toLowerCase());
      } else {
        _apps.add(exe);
      }
    });
    _save();
  }

  bool _selected(String exe) =>
      _apps.any((a) => a.toLowerCase() == exe.toLowerCase());

  @override
  Widget build(BuildContext context) {
    final androidNote = Platform.isAndroid && _mode == SplitMode.onlyListed;

    return Scaffold(
      backgroundColor: VeilColors.bg,
      body: SafeArea(
        child: Column(
          children: [
            _Header(
              title: 'Split tunnelling',
              subtitle: '${_apps.length} app(s) selected',
              onClose: () => Navigator.pop(context),
              action: AppList.supported
                  ? IconButton(
                      tooltip: 'Rescan running apps',
                      onPressed: _loading ? null : _loadRunning,
                      icon: _loading
                          ? const SizedBox(
                              width: 15,
                              height: 15,
                              child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.refresh_rounded, size: 19),
                      color: VeilColors.text2,
                    )
                  : null,
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                children: [
                  VeilSection(
                    title: 'Mode',
                    children: [
                      for (final m in SplitMode.values)
                        VeilListRow(
                          label: m.label,
                          sub: m.description,
                          icon: switch (m) {
                            SplitMode.all => Icons.select_all_rounded,
                            SplitMode.onlyListed => Icons.filter_alt_rounded,
                            SplitMode.exceptListed => Icons.block_flipped,
                          },
                          showDivider: m != SplitMode.values.last,
                          onTap: () {
                            setState(() => _mode = m);
                            _save();
                          },
                          trailing: Icon(
                            _mode == m
                                ? Icons.radio_button_checked_rounded
                                : Icons.radio_button_unchecked_rounded,
                            size: 19,
                            color: _mode == m
                                ? VeilColors.accent
                                : VeilColors.muted,
                          ),
                        ),
                    ],
                  ),

                  if (androidNote)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 16),
                      child: _Note(
                        icon: Icons.info_outline_rounded,
                        text: 'Android can only exclude apps from the tunnel, '
                            'not restrict it to a list. This mode behaves like '
                            '"All apps" here — use "All except selected" instead.',
                      ),
                    ),

                  if (_mode != SplitMode.all) ...[
                    if (_apps.isNotEmpty)
                      VeilSection(
                        title: 'Selected',
                        children: [
                          for (var i = 0; i < _apps.length; i++)
                            VeilListRow(
                              label: _apps[i],
                              icon: Icons.check_circle_rounded,
                              showDivider: i != _apps.length - 1,
                              trailing: IconButton(
                                onPressed: () {
                                  setState(() => _apps.removeAt(i));
                                  _save();
                                },
                                icon: const Icon(Icons.close_rounded, size: 16),
                                color: VeilColors.danger,
                              ),
                            ),
                        ],
                      ),

                    VeilSection(
                      title: Platform.isAndroid ? 'Add a package' : 'Add manually',
                      children: [
                        VeilListRow(
                          label: 'Type a name',
                          sub: Platform.isAndroid
                              ? 'e.g. com.whatsapp'
                              : Platform.isWindows
                                  ? 'e.g. chrome.exe'
                                  : 'e.g. firefox',
                          icon: Icons.keyboard_rounded,
                          showDivider: false,
                          onTap: _addManually,
                          trailing: Icon(Icons.add_rounded,
                              size: 18, color: VeilColors.accent),
                        ),
                      ],
                    ),

                    if (AppList.supported) ...[
                      Padding(
                        padding: const EdgeInsets.fromLTRB(6, 0, 6, 8),
                        child: TextField(
                          controller: _appSearch,
                          onChanged: (_) => setState(() {}),
                          style: VeilText.ui(size: 13),
                          decoration: InputDecoration(
                            isDense: true,
                            hintText: AppList.listsInstalledApps
                                ? 'Search installed apps...'
                                : 'Search running apps...',
                            prefixIcon: Icon(Icons.search_rounded,
                                size: 18, color: VeilColors.muted),
                          ),
                        ),
                      ),
                      VeilSection(
                        title: AppList.listsInstalledApps
                            ? 'Installed applications'
                            : 'Running applications',
                        children: [
                          if (_loading)
                            const VeilListRow(
                              label: 'Loading...',
                              icon: Icons.hourglass_empty_rounded,
                              showDivider: false,
                            )
                          else if (_visibleApps.isEmpty)
                            VeilListRow(
                              label: 'Nothing to show',
                              sub: AppList.listsInstalledApps
                                  ? 'No app matched that search'
                                  : 'Start the app you want to route, then rescan',
                              icon: Icons.search_off_rounded,
                              showDivider: false,
                            )
                          else
                            for (var i = 0; i < _visibleApps.length; i++)
                              _AppRow(
                                app: _visibleApps[i],
                                selected: _selected(_visibleApps[i].executable),
                                showDivider: i != _visibleApps.length - 1,
                                onTap: () => _toggle(_visibleApps[i].executable),
                              ),
                        ],
                      ),
                    ],
                  ],

                  _Note(
                    icon: Icons.autorenew_rounded,
                    text: 'Changes apply the next time you connect.',
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _addManually() async {
    final ctrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: VeilColors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(VeilRadius.lg),
          side: BorderSide(color: VeilColors.border),
        ),
        title: Text('Add application',
            style: VeilText.display(size: 17, weight: 600)),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          style: VeilText.mono(size: 13),
          decoration: InputDecoration(
            hintText: Platform.isAndroid
                ? 'com.example.app'
                : Platform.isWindows
                    ? 'chrome.exe'
                    : 'firefox',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            style: TextButton.styleFrom(foregroundColor: VeilColors.muted),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(
                backgroundColor: VeilColors.accent,
                foregroundColor: VeilColors.onAccent),
            child: const Text('Add'),
          ),
        ],
      ),
    );
    if (ok == true) {
      final v = ctrl.text.trim();
      if (v.isNotEmpty && !_selected(v)) {
        setState(() => _apps.add(v));
        await _save();
      }
    }
    ctrl.dispose();
  }
}

/// Force domains and IPs through the tunnel, or keep them off it.
class RoutingRulesScreen extends StatefulWidget {
  const RoutingRulesScreen({super.key, this.onChanged});
  final VoidCallback? onChanged;

  @override
  State<RoutingRulesScreen> createState() => _RoutingRulesScreenState();
}

class _RoutingRulesScreenState extends State<RoutingRulesScreen> {
  late final List<String> _tunnel = [...Storage.I.tunnelRules];
  late final List<String> _bypass = [...Storage.I.bypassRules];

  Future<void> _save() async {
    await Storage.I.setTunnelRules(_tunnel);
    await Storage.I.setBypassRules(_bypass);
    widget.onChanged?.call();
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: VeilColors.bg,
      body: SafeArea(
        child: Column(
          children: [
            _Header(
              title: 'Domain & IP rules',
              subtitle: '${_tunnel.length} tunnelled · ${_bypass.length} direct',
              onClose: () => Navigator.pop(context),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                children: [
                  _RuleList(
                    title: 'Always through the tunnel',
                    hint: 'netflix.com, 203.0.113.0/24',
                    entries: _tunnel,
                    accent: VeilColors.accent,
                    onAdd: (v) {
                      setState(() => _tunnel.addAll(RoutingRules.splitInput(v)));
                      _save();
                    },
                    onRemove: (i) {
                      setState(() => _tunnel.removeAt(i));
                      _save();
                    },
                  ),
                  _RuleList(
                    title: 'Never through the tunnel',
                    hint: 'bank.example.com, 10.20.0.0/16',
                    entries: _bypass,
                    accent: VeilColors.upload,
                    onAdd: (v) {
                      setState(() => _bypass.addAll(RoutingRules.splitInput(v)));
                      _save();
                    },
                    onRemove: (i) {
                      setState(() => _bypass.removeAt(i));
                      _save();
                    },
                  ),
                  _Note(
                    icon: Icons.info_outline_rounded,
                    text: 'A domain also matches its subdomains. IPs may be '
                        'single addresses or CIDR ranges. "Never" wins over '
                        '"always" if an entry appears in both. Changes apply on '
                        'the next connect.',
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RuleList extends StatelessWidget {
  const _RuleList({
    required this.title,
    required this.hint,
    required this.entries,
    required this.accent,
    required this.onAdd,
    required this.onRemove,
  });

  final String title;
  final String hint;
  final List<String> entries;
  final Color accent;
  final ValueChanged<String> onAdd;
  final ValueChanged<int> onRemove;

  @override
  Widget build(BuildContext context) {
    return VeilSection(
      title: title,
      children: [
        if (entries.isEmpty)
          const VeilListRow(
            label: 'Nothing added yet',
            sub: 'Everything follows the default route',
            icon: Icons.horizontal_rule_rounded,
          )
        else
          for (var i = 0; i < entries.length; i++)
            VeilListRow(
              label: entries[i],
              icon: entries[i].contains(RegExp(r'^\d'))
                  ? Icons.lan_rounded
                  : Icons.language_rounded,
              trailing: IconButton(
                onPressed: () => onRemove(i),
                icon: const Icon(Icons.close_rounded, size: 16),
                color: VeilColors.danger,
              ),
            ),
        VeilListRow(
          label: 'Add entries',
          sub: hint,
          icon: Icons.add_circle_outline_rounded,
          showDivider: false,
          onTap: () => _promptAdd(context),
          trailing: Icon(Icons.add_rounded, size: 18, color: accent),
        ),
      ],
    );
  }

  Future<void> _promptAdd(BuildContext context) async {
    final ctrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: VeilColors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(VeilRadius.lg),
          side: BorderSide(color: VeilColors.border),
        ),
        title: Text(title, style: VeilText.display(size: 16, weight: 600)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: ctrl,
              autofocus: true,
              maxLines: 4,
              minLines: 2,
              style: VeilText.mono(size: 12.5),
              decoration: InputDecoration(hintText: hint),
            ),
            const SizedBox(height: 10),
            Text('One per line, or separated by commas.',
                style: VeilText.ui(size: 11.5, color: VeilColors.muted)),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            style: TextButton.styleFrom(foregroundColor: VeilColors.muted),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(
                backgroundColor: VeilColors.accent,
                foregroundColor: VeilColors.onAccent),
            child: const Text('Add'),
          ),
        ],
      ),
    );
    if (ok == true && ctrl.text.trim().isNotEmpty) onAdd(ctrl.text);
    ctrl.dispose();
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.title,
    required this.subtitle,
    required this.onClose,
    this.action,
  });

  final String title;
  final String subtitle;
  final VoidCallback onClose;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(8, 8, 12, 8),
        child: Row(
          children: [
            IconButton(
              onPressed: onClose,
              icon: const Icon(Icons.arrow_back_rounded, size: 20),
              color: VeilColors.text2,
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(title, style: VeilText.display(size: 18, weight: 600)),
                  Text(subtitle,
                      style: VeilText.ui(size: 11.5, color: VeilColors.muted)),
                ],
              ),
            ),
            ?action,
          ],
        ),
      );
}

class _Note extends StatelessWidget {
  const _Note({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: VeilColors.surface2,
          borderRadius: BorderRadius.circular(VeilRadius.md),
          border: Border.all(color: VeilColors.borderSoft),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 15, color: VeilColors.muted),
            const SizedBox(width: 10),
            Expanded(
              child: Text(text,
                  style: VeilText.ui(
                      size: 11.5, color: VeilColors.muted, height: 1.5)),
            ),
          ],
        ),
      );
}


/// One selectable application. Shows the real launcher icon on Android.
class _AppRow extends StatelessWidget {
  const _AppRow({
    required this.app,
    required this.selected,
    required this.showDivider,
    required this.onTap,
  });

  final AppEntry app;
  final bool selected;
  final bool showDivider;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              child: Row(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: app.icon != null
                        ? Image.memory(app.icon!,
                            width: 32,
                            height: 32,
                            filterQuality: FilterQuality.medium)
                        : Container(
                            width: 32,
                            height: 32,
                            color: VeilColors.tint(0.05),
                            child: Icon(Icons.apps_rounded,
                                size: 16, color: VeilColors.text2),
                          ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(app.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: VeilText.ui(size: 13.5, weight: 500)),
                        if (app.title != null && app.title != app.executable)
                          Text(app.executable,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: VeilText.mono(
                                  size: 10.5, color: VeilColors.muted)),
                      ],
                    ),
                  ),
                  const SizedBox(width: 10),
                  Icon(
                    selected
                        ? Icons.check_box_rounded
                        : Icons.check_box_outline_blank_rounded,
                    size: 19,
                    color: selected ? VeilColors.accent : VeilColors.muted,
                  ),
                ],
              ),
            ),
          ),
        ),
        if (showDivider)
          Divider(height: 1, thickness: 1, color: VeilColors.borderSoft),
      ],
    );
  }
}
