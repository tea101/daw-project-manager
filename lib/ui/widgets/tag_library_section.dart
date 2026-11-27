import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:uuid/uuid.dart';

import '../../generated/l10n/app_localizations.dart';
import '../../models/music_project.dart';
import '../../models/tag_definition.dart';
import '../../providers/providers.dart';
import '../../repository/project_repository.dart';
import '../../services/tag_library_merge.dart';
import '../../utils/phase_colors.dart';
import '../../utils/project_tags.dart';
import '../../utils/tag_phase_rules.dart';
import '../app_snack_bar.dart';
import '../dialogs/color_picker_dialog.dart';
import 'owned_text_controller.dart';

/// Settings > Project tags > Tag library: create, rename, recolour and delete
/// the tags the pickers offer, and set each one's phase rule.
///
/// The library is shared by every profile. Nothing here tags a project; a
/// rename or a delete asks before touching the projects that carry the tag
/// (in every profile), with their count.
class TagLibrarySection extends ConsumerStatefulWidget {
  const TagLibrarySection({super.key});

  @override
  ConsumerState<TagLibrarySection> createState() => _TagLibrarySectionState();
}

class _TagLibrarySectionState extends ConsumerState<TagLibrarySection> {
  static const _uuid = Uuid();

  // --- Every profile's projects -------------------------------------------

  Future<List<ProjectRepository>> _allRepos() async {
    final profiles = ref.read(allProfilesProvider).value ?? const [];
    final repos = <ProjectRepository>[];
    if (profiles.isEmpty) {
      repos.add(await ref.read(repositoryProvider.future));
      return repos;
    }
    for (final profile in profiles) {
      try {
        repos.add(await ref.read(repositoryForProfileProvider(profile.id).future));
      } catch (_) {
        // A profile whose library can't be opened is skipped.
      }
    }
    return repos;
  }

  Future<int> _countTagged(String tag) async {
    var count = 0;
    for (final repo in await _allRepos()) {
      count += repo.getAllProjects().where((p) => projectHasTag(p, tag)).length;
    }
    return count;
  }

  /// Rewrites every project's tags with [edit], in every profile. Returns
  /// how many projects changed.
  Future<int> _editTagsEverywhere(
    List<String> Function(List<String> tags) edit,
  ) async {
    var changed = 0;
    final now = DateTime.now();
    for (final repo in await _allRepos()) {
      for (final MusicProject project in repo.getAllProjects()) {
        final tags = edit(project.tags);
        if (identical(tags, project.tags)) continue;
        await repo.updateProject(project.copyWith(tags: tags, updatedAt: now));
        changed++;
      }
    }
    ref.invalidate(allProjectsStreamProvider);
    return changed;
  }

  // --- Dialogs ---------------------------------------------------------------

  Future<String?> _askName({required String title, String initial = '', String? exceptId}) {
    final active = ref.read(activeTagLibraryProvider);
    return showDialog<String>(
      context: context,
      builder: (ctx) => OwnedTextController(
        text: initial,
        builder: (_, controller) {
          final l10n = AppLocalizations.of(ctx)!;
          return StatefulBuilder(builder: (ctx, setState) {
            final name = normalizeTag(controller.text);
            final taken = name != null &&
                active.any((t) => t.id != exceptId && tagKey(t.name) == tagKey(name));
            final unchanged = name != null && name == initial;
            final ok = name != null && !taken && !unchanged;
            return AlertDialog(
              title: Text(title),
              content: TextField(
                key: const ValueKey('tag-library-name'),
                controller: controller,
                autofocus: true,
                maxLength: kMaxTagLength,
                decoration: InputDecoration(
                  labelText: l10n.tagNameLabel,
                  errorText: taken ? l10n.tagNameExists : null,
                ),
                onChanged: (_) => setState(() {}),
                onSubmitted: (_) {
                  if (ok) Navigator.of(ctx).pop(name);
                },
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: Text(l10n.cancel),
                ),
                FilledButton(
                  key: const ValueKey('tag-library-name-ok'),
                  onPressed: ok ? () => Navigator.of(ctx).pop(name) : null,
                  child: Text(l10n.save),
                ),
              ],
            );
          });
        },
      ),
    );
  }

  Future<void> _add() async {
    final l10n = AppLocalizations.of(context)!;
    final name = await _askName(title: l10n.tagLibraryAdd);
    if (name == null) return;
    await ref
        .read(tagLibraryProvider.notifier)
        .upsert(TagDefinition(id: _uuid.v4(), name: name));
  }

  Future<void> _importInUse(List<String> missing) async {
    await ref.read(tagLibraryProvider.notifier).addAll([
      for (final name in missing) TagDefinition(id: _uuid.v4(), name: name),
    ]);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showAppSnackBar(SnackBar(
      content: Text(AppLocalizations.of(context)!.tagLibraryImported(missing.length)),
    ));
  }

  Future<void> _rename(TagDefinition tag) async {
    final l10n = AppLocalizations.of(context)!;
    final name = await _askName(
      title: l10n.renameTagTitle,
      initial: tag.name,
      exceptId: tag.id,
    );
    if (name == null || !mounted) return;
    final count = await _countTagged(tag.name);
    if (!mounted) return;
    if (count > 0) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(l10n.renameTagTitle),
          content: Text(l10n.renameTagOnProjects(count, tag.name, name)),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text(l10n.cancel),
            ),
            FilledButton(
              key: const ValueKey('tag-rename-confirm'),
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text(l10n.renameTagConfirm),
            ),
          ],
        ),
      );
      if (ok != true) return;
      await _editTagsEverywhere((tags) => renameTag(tags, tag.name, name));
    }
    await ref.read(tagLibraryProvider.notifier).upsert(tag.copyWith(name: name));
  }

  Future<void> _delete(TagDefinition tag) async {
    final l10n = AppLocalizations.of(context)!;
    final count = await _countTagged(tag.name);
    if (!mounted) return;
    // null: cancel; false: keep on projects; true: remove from projects too.
    final removeFromProjects = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.deleteTagTitle(tag.name)),
        content: Text(count > 0
            ? l10n.deleteTagMessage(count)
            : l10n.deleteTagUnused),
        actionsOverflowDirection: VerticalDirection.down,
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(l10n.cancel),
          ),
          if (count > 0)
            OutlinedButton(
              key: const ValueKey('tag-delete-remove'),
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text(l10n.deleteTagRemoveFromProjects(count)),
            ),
          FilledButton(
            key: const ValueKey('tag-delete-keep'),
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(count > 0 ? l10n.deleteTagKeepOnProjects : l10n.delete),
          ),
        ],
      ),
    );
    if (removeFromProjects == null) return;
    if (removeFromProjects) {
      await _editTagsEverywhere((tags) => removeTag(tags, tag.name));
    }
    await ref.read(tagLibraryProvider.notifier).delete(tag.id);
  }

  Future<void> _pickColor(TagDefinition tag) async {
    final color = await showAppColorPicker(
      context,
      title: tag.name,
      current: tag.colorHex != null ? hexToColor(tag.colorHex!) : Colors.grey,
    );
    if (color == null) return;
    await ref
        .read(tagLibraryProvider.notifier)
        .upsert(tag.copyWith(colorHex: colorToHex(color)));
  }

  Future<void> _setRule(TagDefinition tag, String? phase) =>
      ref.read(tagLibraryProvider.notifier).upsert(
            phase == null ? tag.copyWith(clearPhase: true) : tag.copyWith(phase: phase),
          );

  Future<void> _createPreviousVersionPhase() async {
    final l10n = AppLocalizations.of(context)!;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.createPreviousVersionPhaseTitle),
        content: Text(l10n.createPreviousVersionPhaseMessage),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            key: const ValueKey('create-previous-version-phase'),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(l10n.createPhaseButton(kPreviousVersionPhase)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final repo = await ref.read(repositoryProvider.future);
    await repo.setCustomPhases(withPreviousVersionPhase(repo.getCustomPhases()));
    final colors = Map<String, String>.from(repo.getPhaseColors())
      ..putIfAbsent(kPreviousVersionPhase, () => kPreviousVersionPhaseColorHex);
    await repo.setPhaseColors(colors);
    ref.invalidate(customPhasesProvider);
    ref.invalidate(phaseColorsProvider);
  }

  // --- Build -------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final library = ref.watch(activeTagLibraryProvider);
    final fullLibrary = ref.watch(tagLibraryProvider);
    final phases = ref.watch(customPhasesProvider);
    final inUse = ref.watch(availableTagsProvider);
    final missing = [for (final t in inUse) if (tagDefinitionFor(fullLibrary, t) == null) t];
    final needsPreviousVersion =
        ruleNeedsMissingPhase(fullLibrary, phases, kPreviousVersionPhase);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(l10n.tagLibraryTitle, style: theme.textTheme.titleSmall),
        const SizedBox(height: 4),
        Text(l10n.tagLibraryDescription, style: theme.textTheme.bodySmall),
        if (needsPreviousVersion) ...[
          const SizedBox(height: 8),
          Card(
            color: theme.colorScheme.surfaceContainerHighest,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  const Icon(Icons.info_outline, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      l10n.tagPhaseRuleMissingPhase(kPreviousVersionPhase),
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton(
                    key: const ValueKey('offer-previous-version-phase'),
                    onPressed: _createPreviousVersionPhase,
                    child: Text(l10n.createPhaseButton(kPreviousVersionPhase)),
                  ),
                ],
              ),
            ),
          ),
        ],
        const SizedBox(height: 8),
        if (library.isEmpty)
          Text(l10n.tagLibraryEmpty, style: theme.textTheme.bodySmall)
        else
          for (final tag in library)
            _TagRow(
              key: ValueKey('tag-library-row-${tag.id}'),
              tag: tag,
              phases: phases,
              l10n: l10n,
              onRename: () => _rename(tag),
              onDelete: () => _delete(tag),
              onColor: () => _pickColor(tag),
              onRule: (phase) => _setRule(tag, phase),
            ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton.icon(
              key: const ValueKey('tag-library-add'),
              onPressed: _add,
              icon: const Icon(Icons.add, size: 18),
              label: Text(l10n.tagLibraryAdd),
            ),
            if (missing.isNotEmpty)
              OutlinedButton.icon(
                key: const ValueKey('tag-library-import'),
                onPressed: () => _importInUse(missing),
                icon: const Icon(Icons.playlist_add, size: 18),
                label: Text(l10n.tagLibraryImportInUse(missing.length)),
              ),
          ],
        ),
      ],
    );
  }
}

class _TagRow extends StatelessWidget {
  const _TagRow({
    super.key,
    required this.tag,
    required this.phases,
    required this.l10n,
    required this.onRename,
    required this.onDelete,
    required this.onColor,
    required this.onRule,
  });

  final TagDefinition tag;
  final List<String> phases;
  final AppLocalizations l10n;
  final VoidCallback onRename;
  final VoidCallback onDelete;
  final VoidCallback onColor;
  final ValueChanged<String?> onRule;

  @override
  Widget build(BuildContext context) {
    final color = tag.colorHex != null ? hexToColor(tag.colorHex!) : null;
    // A rule naming a phase this profile lacks still shows, marked.
    final options = <String?>[null, ...phases];
    if (tag.phase != null && !phases.contains(tag.phase)) options.add(tag.phase);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          IconButton(
            tooltip: l10n.tagColorTooltip,
            onPressed: onColor,
            icon: Icon(
              color == null ? Icons.circle_outlined : Icons.circle,
              color: color,
              size: 18,
            ),
          ),
          Expanded(
            flex: 2,
            child: Text(tag.name, overflow: TextOverflow.ellipsis),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 3,
            child: DropdownButtonFormField<String?>(
              key: ValueKey('tag-rule-${tag.id}-${tag.phase}'),
              initialValue: tag.phase,
              isExpanded: true,
              decoration: InputDecoration(
                labelText: l10n.tagPhaseRuleLabel,
                isDense: true,
              ),
              items: [
                for (final phase in options)
                  DropdownMenuItem<String?>(
                    value: phase,
                    child: Text(
                      phase == null
                          ? l10n.tagPhaseRuleKeep
                          : phases.contains(phase)
                              ? l10n.tagPhaseRuleSet(phase)
                              : l10n.tagPhaseRuleSetMissing(phase),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: onRule,
            ),
          ),
          IconButton(
            tooltip: l10n.renameTagTitle,
            onPressed: onRename,
            icon: const Icon(Icons.edit_outlined, size: 18),
          ),
          IconButton(
            tooltip: l10n.delete,
            onPressed: onDelete,
            icon: const Icon(Icons.delete_outline, size: 18),
          ),
        ],
      ),
    );
  }
}
