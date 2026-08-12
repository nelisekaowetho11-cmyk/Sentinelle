import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/models.dart';
import '../models/sources.dart';
import '../services/source_registry.dart';
import '../services/subscription_service.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'shell.dart' show mobileTabBarClearance;

/// Manages every place locations come from: panel accounts, subscriptions from
/// other panels, and configs pasted straight in.
///
/// Signing out is a selection here rather than a single button, because with
/// several accounts in play "log out" is ambiguous — the user needs to say
/// which ones.
class SourcesScreen extends StatefulWidget {
  const SourcesScreen({super.key, required this.state});

  final AppState state;

  @override
  State<SourcesScreen> createState() => _SourcesScreenState();
}

class _SourcesScreenState extends State<SourcesScreen> {
  /// Ids the user has ticked. Empty means "nothing selected", which is the
  /// normal browsing state; selection mode turns on as soon as one is ticked.
  final Set<String> _selected = {};
  final Set<String> _refreshing = {};

  bool get _selecting => _selected.isNotEmpty;

  AppState get _state => widget.state;
  SourceRegistry get _sources => _state.sources;

  void _toggle(String id) => setState(() {
        _selected.contains(id) ? _selected.remove(id) : _selected.add(id);
      });

  Future<void> _refreshOne(String id) async {
    setState(() => _refreshing.add(id));
    await _state.refreshSource(id);
    if (!mounted) return;
    setState(() => _refreshing.remove(id));
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 900;
    final all = _sources.sources;

    return SafeArea(
      bottom: false,
      child: Padding(
        padding: EdgeInsets.fromLTRB(
            16, 12, 16, wide ? 16 : mobileTabBarClearance(context)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _header(all.length),
            const SizedBox(height: 12),
            _addBar(),
            const SizedBox(height: 16),
            Expanded(
              child: all.isEmpty
                  ? _empty()
                  : ListView(
                      children: [
                        for (final s in all) _sourceCard(s),
                        const SizedBox(height: 12),
                      ],
                    ),
            ),
            if (_selecting) _selectionBar(),
          ],
        ),
      ),
    );
  }

  Widget _header(int count) => Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('Accounts & sources',
                    style: VeilText.display(size: 18, weight: 600)),
                Text(
                  count == 0
                      ? 'Nothing added yet'
                      : '$count source${count == 1 ? '' : 's'} · '
                          '${_state.servers.length} locations',
                  style: VeilText.ui(size: 11.5, color: VeilColors.muted),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Refresh everything',
            onPressed: _state.busy ? null : () => _state.refresh(),
            icon: _state.busy
                ? const SizedBox(
                    width: 15,
                    height: 15,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.refresh_rounded, size: 19),
            color: VeilColors.text2,
          ),
        ],
      );

  Widget _addBar() => Row(
        children: [
          Expanded(
            child: _AddButton(
              icon: Icons.person_add_alt_rounded,
              label: 'Add account',
              onTap: () => showAddAccountSheet(context, _state),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _AddButton(
              icon: Icons.rss_feed_rounded,
              label: 'Subscription',
              onTap: () => showAddSubscriptionSheet(context, _state),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _AddButton(
              icon: Icons.content_paste_rounded,
              label: 'Paste configs',
              onTap: () => showImportConfigsSheet(context, _state),
            ),
          ),
        ],
      );

  Widget _empty() => Center(
        child: Padding(
          padding: const EdgeInsets.all(30),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.travel_explore_rounded,
                  size: 34, color: VeilColors.muted),
              const SizedBox(height: 12),
              Text(
                'Sign into a panel, add a subscription from another one, or '
                'paste your own configs. Any of the three is enough to '
                'connect — an account is not required.',
                textAlign: TextAlign.center,
                style: VeilText.ui(
                    size: 12.5, color: VeilColors.muted, height: 1.6),
              ),
            ],
          ),
        ),
      );

  // ── One source ─────────────────────────────────────────────────────────────

  Widget _sourceCard(LocationSource s) {
    final ticked = _selected.contains(s.id);
    final servers = _sources.serversOf(s.id);
    final profile = _sources.profileOf(s.id);
    final usage = _sources.usageOf(s.id);
    final busy = _refreshing.contains(s.id);

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: GestureDetector(
        // Long-press starts selection, exactly like picking files.
        onLongPress: () => _toggle(s.id),
        onTap: _selecting ? () => _toggle(s.id) : null,
        behavior: HitTestBehavior.opaque,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          padding: const EdgeInsets.fromLTRB(13, 12, 8, 12),
          decoration: BoxDecoration(
            color: ticked ? VeilColors.accentTint : VeilColors.surface,
            border: Border.all(
                color: ticked ? VeilColors.accent : VeilColors.border),
            borderRadius: BorderRadius.circular(VeilRadius.md),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  if (_selecting)
                    Padding(
                      padding: const EdgeInsets.only(right: 10),
                      child: Icon(
                        ticked
                            ? Icons.check_box_rounded
                            : Icons.check_box_outline_blank_rounded,
                        size: 19,
                        color:
                            ticked ? VeilColors.accent : VeilColors.muted,
                      ),
                    ),
                  _KindBadge(kind: s.kind),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Text(s.displayLabel,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style:
                                      VeilText.ui(size: 13.5, weight: 600)),
                            ),
                            if (s.pinned) ...[
                              const SizedBox(width: 6),
                              Tooltip(
                                message: 'Its locations are listed first',
                                child: Icon(Icons.push_pin_rounded,
                                    size: 12, color: VeilColors.accent),
                              ),
                            ],
                          ],
                        ),
                        const SizedBox(height: 2),
                        Text(
                          _subtitle(s, servers.length),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: VeilText.ui(
                            size: 11,
                            color: s.error != null
                                ? VeilColors.danger
                                : VeilColors.muted,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (busy)
                    const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 10),
                      child: SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2)),
                    )
                  else ...[
                    VeilSwitch(
                      value: s.enabled,
                      onChanged: (v) => _state.setSourceEnabled(s.id, v),
                    ),
                    _menu(s),
                  ],
                ],
              ),
              if (profile != null || usage != null) ...[
                const SizedBox(height: 10),
                _quotaLine(profile: profile, usage: usage),
              ],
            ],
          ),
        ),
      ),
    );
  }

  String _subtitle(LocationSource s, int count) {
    if (s.error != null) return s.error!;
    final bits = <String>[
      '$count location${count == 1 ? '' : 's'}',
      if (!s.enabled) 'disabled',
      if (s.lastRefresh != null) 'updated ${_ago(s.lastRefresh!)}',
    ];
    return bits.join(' · ');
  }

  static String _ago(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inSeconds < 90) return 'just now';
    if (d.inMinutes < 60) return '${d.inMinutes}m ago';
    if (d.inHours < 24) return '${d.inHours}h ago';
    return '${d.inDays}d ago';
  }

  Widget _quotaLine({
    required Profile? profile,
    required SubscriptionUsage? usage,
  }) {
    final double pct;
    final String left;
    final String extra;

    if (profile != null) {
      pct = profile.unlimited ? 0.0 : profile.trafficPct;
      left = profile.unlimited
          ? '∞ remaining'
          : '${(profile.trafficLeftGb ?? 0).toStringAsFixed(1)} GB left';
      extra = profile.daysLeft == null ? '' : '${profile.daysLeft}d';
    } else {
      usage!;
      pct = usage.usedPct;
      left = usage.unlimited
          ? '∞ remaining'
          : '${_gb(usage.totalBytes - usage.usedBytes)} left';
      extra = usage.expiry == null
          ? ''
          : '${usage.expiry!.difference(DateTime.now()).inDays}d';
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        QuotaBar(pct: pct, height: 3),
        const SizedBox(height: 5),
        Row(
          children: [
            Text(left,
                style: VeilText.mono(size: 10, color: VeilColors.muted)),
            const Spacer(),
            if (extra.isNotEmpty)
              Text(extra,
                  style: VeilText.mono(size: 10, color: VeilColors.muted)),
          ],
        ),
      ],
    );
  }

  static String _gb(int bytes) =>
      '${(bytes / 1073741824).clamp(0, double.infinity).toStringAsFixed(1)} GB';

  Widget _menu(LocationSource s) => PopupMenuButton<String>(
        tooltip: 'More',
        icon: Icon(Icons.more_vert_rounded,
            size: 18, color: VeilColors.muted),
        color: VeilColors.surface2,
        onSelected: (value) async {
          switch (value) {
            case 'refresh':
              await _refreshOne(s.id);
            case 'rename':
              await _rename(s);
            case 'pin':
              await _state.setSourcePinned(s.id, !s.pinned);
            case 'select':
              _toggle(s.id);
            case 'remove':
              await _confirmRemove([s.id], s.displayLabel);
          }
        },
        itemBuilder: (context) => [
          if (s.kind != SourceKind.manual)
            const PopupMenuItem(value: 'refresh', child: Text('Refresh now')),
          const PopupMenuItem(value: 'rename', child: Text('Rename')),
          PopupMenuItem(
            value: 'pin',
            child: Text(s.pinned ? 'Stop showing first' : 'Show locations first'),
          ),
          const PopupMenuItem(value: 'select', child: Text('Select')),
          PopupMenuItem(
            value: 'remove',
            child: Text(
              s.isAccount ? 'Log out' : 'Remove',
              style: TextStyle(color: VeilColors.danger),
            ),
          ),
        ],
      );

  // ── Selection actions ──────────────────────────────────────────────────────

  Widget _selectionBar() => Container(
        margin: const EdgeInsets.only(top: 10),
        padding: const EdgeInsets.fromLTRB(13, 10, 10, 10),
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
              onPressed: () => _confirmRemove(
                  _selected.toList(), '${_selected.length} sources'),
              child: Text('Log out selected',
                  style: VeilText.ui(
                      size: 12.5, weight: 600, color: VeilColors.danger)),
            ),
          ],
        ),
      );

  Future<void> _rename(LocationSource s) async {
    final name = await promptForText(
      context,
      title: 'Rename source',
      hint: s.displayLabel,
      initial: s.label,
    );
    if (name != null) await _state.renameSource(s.id, name);
  }

  Future<void> _confirmRemove(List<String> ids, String what) async {
    final accounts = ids
        .map(_sources.sourceById)
        .whereType<LocationSource>()
        .where((s) => s.isAccount)
        .length;

    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: VeilColors.surface,
        title: Text(accounts > 0 ? 'Log out?' : 'Remove?',
            style: VeilText.display(size: 16, weight: 600)),
        content: Text(
          'Remove $what? Their locations disappear from the picker, along '
          'with any names or map positions you set for them.',
          style: VeilText.ui(size: 12.5, color: VeilColors.text2, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(accounts > 0 ? 'Log out' : 'Remove',
                style: TextStyle(color: VeilColors.danger)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await _state.removeSources(ids);
    if (mounted) setState(_selected.clear);
  }
}

// ── Add flows ────────────────────────────────────────────────────────────────

/// Signs into an additional panel without disturbing the ones already added.
Future<void> showAddAccountSheet(BuildContext context, AppState state) async {
  final url = TextEditingController(text: state.sources.accounts.isEmpty
      ? ''
      : state.sources.accounts.first.baseUrl);
  final user = TextEditingController();
  final pass = TextEditingController();

  await _showSheet(
    context,
    title: 'Add an account',
    subtitle: 'Sign into another panel. Existing accounts stay signed in.',
    fields: [
      _SheetField(label: 'Panel address', controller: url, hint: 'panel.example.com'),
      _SheetField(label: 'Username', controller: user, hint: 'pvb…'),
      _SheetField(label: 'Password', controller: pass, obscure: true),
    ],
    action: 'Sign in',
    onSubmit: () async {
      if (url.text.trim().isEmpty || user.text.trim().isEmpty) {
        return 'Panel address and username are required.';
      }
      final ok = await state.login(url.text, user.text, pass.text,
          remember: true);
      return ok ? null : (state.authError ?? 'Could not sign in.');
    },
  );
}

/// Adds a subscription URL from any panel. Works with no account signed in.
Future<void> showAddSubscriptionSheet(
    BuildContext context, AppState state) async {
  final url = TextEditingController();
  final name = TextEditingController();

  await _showSheet(
    context,
    title: 'Add a subscription',
    subtitle:
        'Paste a subscription link from any panel. Its servers join your '
        'locations list in their own group.',
    fields: [
      _SheetField(
          label: 'Subscription URL', controller: url, hint: 'https://…/sub/…'),
      _SheetField(
          label: 'Name (optional)', controller: name, hint: 'Work panel'),
    ],
    action: 'Add',
    onSubmit: () => state.addSubscription(url.text, label: name.text),
  );
}

/// Imports one or many share links from the clipboard or a paste.
Future<void> showImportConfigsSheet(
    BuildContext context, AppState state) async {
  final text = TextEditingController();
  // Pre-fill from the clipboard: the overwhelmingly common case is that the
  // user copied a config a second ago and is here to paste it.
  final clip = await Clipboard.getData(Clipboard.kTextPlain);
  final clipText = clip?.text ?? '';
  if (clipText.contains('://')) text.text = clipText.trim();

  if (!context.mounted) return;
  await _showSheet(
    context,
    title: 'Paste configs',
    subtitle:
        'One link per line — vless://, vmess://, trojan:// or ss://. They are '
        'added to your locations and work with or without an account.',
    fields: [
      _SheetField(label: 'Configs', controller: text, maxLines: 6),
    ],
    action: 'Import',
    onSubmit: () async {
      final outcome = await state.importConfigs(text.text);
      return outcome.ok ? null : outcome.summary;
    },
    successMessage: () => 'Imported',
  );
}

// ── Sheet plumbing ───────────────────────────────────────────────────────────

class _SheetField {
  _SheetField({
    required this.label,
    required this.controller,
    this.hint = '',
    this.obscure = false,
    this.maxLines = 1,
  });

  final String label;
  final TextEditingController controller;
  final String hint;
  final bool obscure;
  final int maxLines;
}

/// One modal shape for all three add flows, so they behave identically:
/// validate, show the failure inline, close only on success.
Future<void> _showSheet(
  BuildContext context, {
  required String title,
  required String subtitle,
  required List<_SheetField> fields,
  required String action,
  required Future<String?> Function() onSubmit,
  String Function()? successMessage,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: VeilColors.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
    ),
    builder: (sheetContext) => _SheetBody(
      title: title,
      subtitle: subtitle,
      fields: fields,
      action: action,
      onSubmit: onSubmit,
      successMessage: successMessage,
    ),
  );
}

class _SheetBody extends StatefulWidget {
  const _SheetBody({
    required this.title,
    required this.subtitle,
    required this.fields,
    required this.action,
    required this.onSubmit,
    this.successMessage,
  });

  final String title;
  final String subtitle;
  final List<_SheetField> fields;
  final String action;
  final Future<String?> Function() onSubmit;
  final String Function()? successMessage;

  @override
  State<_SheetBody> createState() => _SheetBodyState();
}

class _SheetBodyState extends State<_SheetBody> {
  bool _busy = false;
  String? _error;

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final error = await widget.onSubmit();
    if (!mounted) return;
    if (error != null) {
      setState(() {
        _busy = false;
        _error = error;
      });
      return;
    }
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: 18,
        right: 18,
        top: 16,
        // Lifts the sheet clear of the keyboard, which otherwise covers the
        // very field being typed into.
        bottom: MediaQuery.viewInsetsOf(context).bottom + 18,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: Container(
              width: 38,
              height: 4,
              margin: const EdgeInsets.only(bottom: 14),
              decoration: BoxDecoration(
                color: VeilColors.muted,
                borderRadius: BorderRadius.circular(99),
              ),
            ),
          ),
          Text(widget.title, style: VeilText.display(size: 16, weight: 600)),
          const SizedBox(height: 5),
          Text(widget.subtitle,
              style: VeilText.ui(
                  size: 11.5, color: VeilColors.muted, height: 1.5)),
          const SizedBox(height: 16),
          for (final f in widget.fields) ...[
            Text(f.label,
                style: VeilText.ui(size: 11, color: VeilColors.text2)),
            const SizedBox(height: 5),
            TextField(
              controller: f.controller,
              obscureText: f.obscure,
              maxLines: f.obscure ? 1 : f.maxLines,
              minLines: 1,
              style: VeilText.ui(size: 13),
              decoration: InputDecoration(
                isDense: true,
                hintText: f.hint.isEmpty ? null : f.hint,
              ),
            ),
            const SizedBox(height: 12),
          ],
          if (_error != null) ...[
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: VeilColors.danger.withValues(alpha: 0.10),
                border:
                    Border.all(color: VeilColors.danger.withValues(alpha: 0.3)),
                borderRadius: BorderRadius.circular(VeilRadius.sm),
              ),
              child: Text(_error!,
                  style: VeilText.ui(
                      size: 11.5, color: VeilColors.danger, height: 1.5)),
            ),
            const SizedBox(height: 12),
          ],
          PrimaryActionButton(
            label: widget.action,
            busyLabel: 'Working…',
            busy: _busy,
            onTap: _submit,
          ),
        ],
      ),
    );
  }
}

class _KindBadge extends StatelessWidget {
  const _KindBadge({required this.kind});

  final SourceKind kind;

  @override
  Widget build(BuildContext context) {
    final (icon, colour) = switch (kind) {
      SourceKind.account => (Icons.account_circle_rounded, VeilColors.accent),
      SourceKind.subscription => (Icons.rss_feed_rounded, VeilColors.info),
      SourceKind.manual => (Icons.content_paste_rounded, VeilColors.warn),
    };
    return Container(
      width: 32,
      height: 32,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: colour.withValues(alpha: 0.12),
        border: Border.all(color: colour.withValues(alpha: 0.3)),
        borderRadius: BorderRadius.circular(9),
      ),
      child: Icon(icon, size: 16, color: colour),
    );
  }
}

class _AddButton extends StatelessWidget {
  const _AddButton({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Clickable(child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 11, horizontal: 8),
          decoration: BoxDecoration(
            color: VeilColors.surface2,
            border: Border.all(color: VeilColors.border),
            borderRadius: BorderRadius.circular(VeilRadius.sm),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 17, color: VeilColors.text2),
              const SizedBox(height: 5),
              Text(label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: VeilText.ui(
                      size: 11, weight: 500, color: VeilColors.text2)),
            ],
          ),
        ),
      ));
}
