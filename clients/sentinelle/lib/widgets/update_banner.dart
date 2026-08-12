import 'dart:io';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../state/app_state.dart';
import '../theme.dart';

/// "Version X is available" on the connect page.
///
/// The check runs at every launch, but it used to only show up on the Settings
/// screen — somewhere nobody looks unless they already suspect something. This
/// puts the answer on the page the app opens on, and offers to do the update
/// rather than handing over a link.
class UpdateBanner extends StatelessWidget {
  const UpdateBanner({super.key, required this.state, this.compact = false});

  final AppState state;
  final bool compact;

  /// True when there is anything to show, so callers can decide their own
  /// spacing without duplicating the conditions.
  static bool visibleFor(AppState state) =>
      state.update.available &&
      (!state.updateNoticeDismissed || state.updateProgress != null);

  @override
  Widget build(BuildContext context) {
    if (!visibleFor(state)) return const SizedBox.shrink();

    final update = state.update;
    final progress = state.updateProgress;
    final downloading = progress != null;

    return Container(
      padding: EdgeInsets.fromLTRB(compact ? 12 : 14, 11, compact ? 10 : 12, 11),
      decoration: BoxDecoration(
        color: VeilColors.accent.withValues(alpha: 0.10),
        border: Border.all(color: VeilColors.accent.withValues(alpha: 0.38)),
        borderRadius: BorderRadius.circular(VeilRadius.md),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: EdgeInsets.only(top: 1),
            child: Icon(Icons.system_update_alt_rounded,
                size: 16, color: VeilColors.accent),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  downloading
                      ? 'Downloading version ${update.latest}…'
                      : 'Version ${update.latest} is available',
                  style: VeilText.ui(
                      size: 12.5, weight: 600, color: VeilColors.accent),
                ),
                const SizedBox(height: 3),
                Text(
                  state.updateError ??
                      (update.notes.trim().isEmpty
                          ? 'You are running ${update.current}.'
                          : update.notes.trim()),
                  maxLines: compact ? 2 : 3,
                  overflow: TextOverflow.ellipsis,
                  style: VeilText.ui(
                    size: 11.5,
                    color: state.updateError != null
                        ? VeilColors.danger
                        : VeilColors.text2,
                    height: 1.5,
                  ),
                ),
                if (downloading) ...[
                  const SizedBox(height: 8),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(VeilRadius.pill),
                    child: LinearProgressIndicator(
                      // A server that sends no Content-Length gives us nothing
                      // to divide by, so the bar sweeps instead of lying.
                      value: progress > 0 ? progress : null,
                      minHeight: 3,
                      backgroundColor: VeilColors.tint(0.08),
                      valueColor:
                          AlwaysStoppedAnimation(VeilColors.accent),
                    ),
                  ),
                ] else ...[
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      if (update.installable)
                        _Action(
                          label: Platform.isAndroid
                              ? 'Download & install'
                              : 'Download & run',
                          icon: Icons.download_rounded,
                          onTap: () => _install(context),
                        )
                      else if (update.url.isNotEmpty)
                        _Action(
                          label: 'Open download page',
                          icon: Icons.open_in_new_rounded,
                          onTap: () => launchUrl(Uri.parse(update.url),
                              mode: LaunchMode.externalApplication),
                        ),
                    ],
                  ),
                ],
              ],
            ),
          ),
          // A mandatory update is the provider saying the old build no longer
          // works, so it does not get a dismiss button.
          if (!update.mandatory && !downloading)
            IconButton(
              tooltip: 'Not now',
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
              iconSize: 15,
              color: VeilColors.muted,
              onPressed: state.dismissUpdateNotice,
              icon: const Icon(Icons.close_rounded),
            ),
        ],
      ),
    );
  }

  Future<void> _install(BuildContext context) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final quit = await state.installUpdate();
    if (!quit) {
      if (state.updateError != null && messenger != null) {
        messenger.showSnackBar(SnackBar(
          backgroundColor: VeilColors.surface,
          content: Text(state.updateError!, style: VeilText.ui(size: 12.5)),
        ));
      }
      return;
    }
    // The installer is running and cannot replace files this process holds
    // open. Take the core down properly on the way out rather than being
    // killed with a tunnel still up.
    await state.shutdown();
    exit(0);
  }
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
            color: VeilColors.accent.withValues(alpha: 0.14),
            border: Border.all(color: VeilColors.accent.withValues(alpha: 0.40)),
            borderRadius: BorderRadius.circular(VeilRadius.sm),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 12, color: VeilColors.accent),
              const SizedBox(width: 5),
              Text(label,
                  style: VeilText.ui(
                      size: 11, weight: 600, color: VeilColors.accent)),
            ],
          ),
        ),
      ));
}
