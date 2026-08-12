import 'dart:io';

import 'package:flutter/material.dart';

import '../services/vpn/desktop_engine.dart';
import '../services/vpn/elevation.dart';
import '../state/app_state.dart';
import '../theme.dart';
import 'common.dart';

/// Explains a failed connection instead of leaving the word "Error" on screen.
///
/// Three layers, because the useful detail is different every time: a sentence
/// naming the likely cause, the exact message underneath it, and the core's own
/// output behind a button for when neither is enough. The last one matters —
/// sing-box says precisely what it did not like, and that line was previously
/// buried on the Stats page.
class ErrorPanel extends StatelessWidget {
  const ErrorPanel({super.key, required this.state, this.compact = false});

  final AppState state;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final message = state.connectionError;
    if (message == null) return const SizedBox.shrink();

    return Container(
      padding: EdgeInsets.fromLTRB(compact ? 12 : 14, 11, compact ? 10 : 12, 11),
      decoration: BoxDecoration(
        color: VeilColors.dangerSurface.withValues(alpha: 0.94),
        border: Border.all(color: VeilColors.danger.withValues(alpha: 0.45)),
        borderRadius: BorderRadius.circular(VeilRadius.md),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: EdgeInsets.only(top: 1),
            child: Icon(Icons.error_outline_rounded,
                size: 16, color: VeilColors.danger),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('Could not connect',
                    style: VeilText.ui(
                        size: 12.5, weight: 600, color: VeilColors.danger)),
                const SizedBox(height: 3),
                Text(
                  message,
                  // Long enough to read the whole diagnosis; the log button
                  // covers anything longer.
                  maxLines: compact ? 4 : 6,
                  overflow: TextOverflow.ellipsis,
                  style: VeilText.ui(
                      size: 11.5, color: VeilColors.text2, height: 1.5),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    // Elevation is the one failure the user can fix from here,
                    // so it leads — telling someone "VPN mode needs
                    // administrator rights" and then offering only "Retry",
                    // which will fail the same way, is a dead end.
                    if (_needsElevation) ...[
                      _Action(
                        label: 'Restart as admin',
                        icon: Icons.admin_panel_settings_rounded,
                        onTap: () => _relaunchElevated(context),
                      ),
                      const SizedBox(width: 8),
                    ],
                    _Action(
                      label: 'Retry',
                      icon: Icons.refresh_rounded,
                      onTap: state.retryNow,
                    ),
                    const SizedBox(width: 8),
                    if (_hasLog) ...[
                      _Action(
                        label: 'Core log',
                        icon: Icons.terminal_rounded,
                        onTap: () => showCoreLog(context, state),
                      ),
                      const SizedBox(width: 8),
                    ],
                    _Action(
                      label: 'Copy',
                      icon: Icons.copy_rounded,
                      onTap: () => copyToClipboard(
                          context, _report(), 'Error details copied'),
                    ),
                  ],
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Dismiss',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
            iconSize: 15,
            color: VeilColors.muted,
            onPressed: state.clearConnectionError,
            icon: const Icon(Icons.close_rounded),
          ),
        ],
      ),
    );
  }

  bool get _hasLog {
    final e = state.engine;
    return e is DesktopVpnEngine && e.log.isNotEmpty;
  }

  /// True when this failure is "the process is not elevated" and we can do
  /// something about it. Both halves matter: on Linux and macOS there is no
  /// equivalent of the UAC prompt, so the panel says what to do by hand
  /// instead of offering a button that cannot work.
  bool get _needsElevation => state.needsElevation && Elevation.canRelaunch;

  /// Restarts the app with administrator rights and hands the tunnel over.
  ///
  /// Declining the prompt leaves this process running exactly as it was, so
  /// that has to be said rather than looking like nothing happened.
  Future<void> _relaunchElevated(BuildContext context) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    await state.shutdown();
    if (await Elevation.relaunchElevated()) exit(0);
    messenger?.showSnackBar(SnackBar(
      backgroundColor: VeilColors.surface,
      content: Text('Not restarted. ${Elevation.manualInstruction}',
          style: VeilText.ui(size: 12.5)),
    ));
  }

  /// Everything worth pasting into a support message, in one go.
  String _report() {
    final e = state.engine;
    final server = state.activeServer ?? state.selectedServer;
    final buffer = StringBuffer()
      ..writeln(state.connectionError)
      ..writeln()
      ..writeln('Platform: ${Platform.operatingSystem} '
          '${Platform.operatingSystemVersion}')
      ..writeln('Mode: ${state.engineOptions.mode.name}');
    if (server != null) {
      buffer.writeln('Server: ${server.displayName} '
          '(${server.protoLabel}, ${server.address}:${server.port})');
    }
    if (e is DesktopVpnEngine && e.log.isNotEmpty) {
      buffer
        ..writeln()
        ..writeln('--- core log ---')
        ..writeln(e.log.join('\n'));
    }
    return buffer.toString();
  }
}

/// The core's own output, verbatim.
Future<void> showCoreLog(BuildContext context, AppState state) {
  final engine = state.engine;
  final lines = engine is DesktopVpnEngine ? engine.log : const <String>[];

  return showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      backgroundColor: VeilColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(VeilRadius.lg),
        side: BorderSide(color: VeilColors.border),
      ),
      title: Row(
        children: [
          Text('Core log', style: VeilText.display(size: 16, weight: 600)),
          const Spacer(),
          Text('${lines.length} lines',
              style: VeilText.ui(size: 11, color: VeilColors.muted)),
        ],
      ),
      content: SizedBox(
        width: 620,
        height: 380,
        child: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: VeilColors.bg,
            border: Border.all(color: VeilColors.borderSoft),
            borderRadius: BorderRadius.circular(VeilRadius.sm),
          ),
          child: lines.isEmpty
              ? Center(
                  child: Text('The core produced no output.',
                      style:
                          VeilText.ui(size: 12, color: VeilColors.muted)),
                )
              : SelectableText(
                  lines.join('\n'),
                  style: VeilText.mono(size: 11, height: 1.5),
                ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () =>
              copyToClipboard(context, lines.join('\n'), 'Core log copied'),
          child: const Text('Copy'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
      ],
    ),
  );
}

class _Action extends StatelessWidget {
  const _Action({
    required this.label,
    required this.icon,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Clickable(child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
          decoration: BoxDecoration(
            color: VeilColors.danger.withValues(alpha: 0.12),
            border: Border.all(color: VeilColors.danger.withValues(alpha: 0.35)),
            borderRadius: BorderRadius.circular(VeilRadius.sm),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 12, color: VeilColors.danger),
              const SizedBox(width: 5),
              Text(label,
                  style: VeilText.ui(
                      size: 11, weight: 600, color: VeilColors.danger)),
            ],
          ),
        ),
      ));
}
