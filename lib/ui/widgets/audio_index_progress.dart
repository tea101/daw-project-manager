import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../generated/l10n/app_localizations.dart';
import '../../providers/providers.dart';
import 'semantics_safe.dart';

/// The audio index at work (v3.0.6): "Reading audio 12 of 340", the project
/// in hand in a tooltip, and a button to stop. Nothing while idle. Its own
/// repaint boundary, watching only the counters — the projects table never
/// repaints for it.
class AudioIndexProgress extends ConsumerWidget {
  const AudioIndexProgress({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final (running, done, total, current) = ref.watch(audioIndexProvider
        .select((s) => (s.running, s.done, s.total, s.current)));
    if (!running || total == 0) return const SizedBox.shrink();
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    return RepaintBoundary(
      child: Padding(
        padding: const EdgeInsets.only(left: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                value: total == 0 ? null : done / total,
              ),
            ),
            const SizedBox(width: 6),
            StandaloneTooltip(
              message: current ?? '',
              child: Text(
                l10n.audioIndexProgress(done, total),
                style: theme.textTheme.bodySmall,
              ),
            ),
            IconButton(
              tooltip: l10n.audioIndexCancel,
              visualDensity: VisualDensity.compact,
              iconSize: 16,
              icon: const Icon(Icons.close),
              onPressed: () => ref.read(audioIndexProvider.notifier).cancel(),
            ),
          ],
        ),
      ),
    );
  }
}
