import 'package:material_ui/material_ui.dart';

import '../../generated/l10n/app_localizations.dart';
import '../../models/music_project.dart';
import '../../models/tag_definition.dart';
import '../../utils/tag_phase_rules.dart';

/// Asks the questions [planTagPhaseQuestion] says to ask after tags were
/// added to [projects]: which phase, when the added tags' rules disagree, and
/// always a confirmation showing how many projects would change.
///
/// Returns the chosen phase and the projects to move to it, or null when no
/// rule applies or the user keeps the current phase. Changes nothing itself.
Future<({String phase, List<MusicProject> projects})?> askTagPhaseChange(
  BuildContext context, {
  required List<MusicProject> projects,
  required Iterable<String> addedTags,
  required List<TagDefinition> library,
  required List<String> phases,
}) async {
  final question = planTagPhaseQuestion(
    projects: projects,
    addedTags: addedTags,
    library: library,
    phases: phases,
  );
  String phase;
  switch (question) {
    case NoPhaseQuestion():
      return null;
    case ConfirmPhaseChange(phase: final p):
      phase = p;
    case ChoosePhase(phases: final options):
      final chosen = await showDialog<String>(
        context: context,
        builder: (_) => _ChoosePhaseDialog(phases: options),
      );
      if (chosen == null || !context.mounted) return null;
      phase = chosen;
  }
  final affected = projectsToMove(projects, phase);
  if (affected.isEmpty) return null;
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (ctx) {
      final l10n = AppLocalizations.of(ctx)!;
      return AlertDialog(
        title: Text(l10n.tagPhaseConfirmTitle),
        content: Text(l10n.tagPhaseConfirmMessage(affected.length, phase)),
        actions: [
          TextButton(
            key: const ValueKey('tag-phase-keep'),
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(l10n.tagPhaseKeepCurrent),
          ),
          FilledButton(
            key: const ValueKey('tag-phase-change'),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(l10n.tagPhaseChange),
          ),
        ],
      );
    },
  );
  if (confirmed != true) return null;
  return (phase: phase, projects: affected);
}

class _ChoosePhaseDialog extends StatelessWidget {
  const _ChoosePhaseDialog({required this.phases});

  final List<String> phases;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return AlertDialog(
      title: Text(l10n.tagPhaseConflictTitle),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(l10n.tagPhaseConflictMessage),
          const SizedBox(height: 12),
          for (final phase in phases)
            ListTile(
              key: ValueKey('tag-phase-option-$phase'),
              dense: true,
              leading: const Icon(Icons.flag_outlined),
              title: Text(phase),
              onTap: () => Navigator.of(context).pop(phase),
            ),
        ],
      ),
      actions: [
        TextButton(
          key: const ValueKey('tag-phase-choose-keep'),
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.tagPhaseKeepCurrent),
        ),
      ],
    );
  }
}
