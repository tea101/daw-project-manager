import '../models/music_project.dart';
import '../models/tag_definition.dart';
import '../services/tag_library_merge.dart';

/// Tag-to-phase rules: adding a tag that has a rule *offers* to move the
/// project to that phase. Pure functions, so every decision is testable; the
/// UI only asks the questions they say to ask.
///
/// - Only adding a tag triggers a rule; removing one never moves a phase back.
/// - A rule naming a phase this profile doesn't have does nothing.
/// - Nothing changes without the user's confirmation, with the count of
///   affected projects shown first; conflicting rules are a question too.

/// The distinct phases [addedTags] offer, in the order the tags were added —
/// only phases [phases] (this profile's) actually holds.
List<String> phaseTargetsForTags(
  Iterable<String> addedTags,
  List<TagDefinition> library,
  List<String> phases,
) {
  final targets = <String>[];
  for (final tag in addedTags) {
    final rule = tagDefinitionFor(library, tag)?.phase;
    if (rule == null) continue;
    final phase = phases.where((p) => p == rule).firstOrNull;
    if (phase != null && !targets.contains(phase)) targets.add(phase);
  }
  return targets;
}

/// The projects moving to [phase] would actually change: those not already
/// in it.
List<MusicProject> projectsToMove(Iterable<MusicProject> projects, String phase) =>
    [for (final p in projects) if (p.status != phase) p];

/// What to ask after tags were added to [projects].
sealed class TagPhaseQuestion {
  const TagPhaseQuestion();
}

/// No rule applies, or every project is already in the phase: ask nothing.
class NoPhaseQuestion extends TagPhaseQuestion {
  const NoPhaseQuestion();
}

/// One phase is offered: confirm moving [affected] projects to [phase].
class ConfirmPhaseChange extends TagPhaseQuestion {
  const ConfirmPhaseChange(this.phase, this.affected);
  final String phase;
  final List<MusicProject> affected;
}

/// The added tags offer different phases: ask which, then confirm.
class ChoosePhase extends TagPhaseQuestion {
  const ChoosePhase(this.phases);
  final List<String> phases;
}

TagPhaseQuestion planTagPhaseQuestion({
  required Iterable<MusicProject> projects,
  required Iterable<String> addedTags,
  required List<TagDefinition> library,
  required List<String> phases,
}) {
  final targets = phaseTargetsForTags(addedTags, library, phases);
  if (targets.isEmpty) return const NoPhaseQuestion();
  if (targets.length > 1) return ChoosePhase(targets);
  final affected = projectsToMove(projects, targets.single);
  if (affected.isEmpty) return const NoPhaseQuestion();
  return ConfirmPhaseChange(targets.single, affected);
}

/// Whether some rule in [library] names [phase] but [phases] lacks it — the
/// cue for Settings to offer creating it.
bool ruleNeedsMissingPhase(
  List<TagDefinition> library,
  List<String> phases,
  String phase,
) =>
    activeTagLibrary(library).any((t) => t.phase == phase) &&
    !phases.contains(phase);
