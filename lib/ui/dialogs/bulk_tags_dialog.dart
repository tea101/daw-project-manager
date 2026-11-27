import 'package:material_ui/material_ui.dart';

import '../../generated/l10n/app_localizations.dart';
import '../../utils/project_tags.dart';
import '../widgets/project_tags_editor.dart';

/// What the bulk tag dialog asked for: put [tags] on every selected
/// project, or take them off every one that has them.
typedef BulkTagChange = ({List<String> tags, bool add});

/// Adds tags to, or removes one from, every selected project at once (#109).
///
/// Adding: tick any number of tags from the tag library (and tags already in
/// use) and press "Add selected tags", or type a new one and press Enter —
/// which adds it together with any ticked. Removing: the × on a tag present
/// on the selection takes that tag off. Returns null when the user cancels.
/// The caller canonicalizes and writes — the dialog only reports what was
/// picked.
///
/// [suggestions] is every tag the pickers offer (library first); [removable]
/// is the tags present on at least one selected project.
Future<BulkTagChange?> showBulkTagsDialog(
  BuildContext context, {
  required int projectCount,
  required List<String> suggestions,
  required List<String> removable,
}) {
  return showDialog<BulkTagChange>(
    context: context,
    builder: (_) => BulkTagsDialog(
      projectCount: projectCount,
      suggestions: suggestions,
      removable: removable,
    ),
  );
}

class BulkTagsDialog extends StatefulWidget {
  const BulkTagsDialog({
    super.key,
    required this.projectCount,
    required this.suggestions,
    required this.removable,
  });

  final int projectCount;
  final List<String> suggestions;
  final List<String> removable;

  @override
  State<BulkTagsDialog> createState() => _BulkTagsDialogState();
}

class _BulkTagsDialogState extends State<BulkTagsDialog> {
  final List<String> _selected = [];

  void _toggle(String tag, bool on) => setState(() {
        if (on) {
          if (!containsTag(_selected, tag)) _selected.add(tag);
        } else {
          _selected.removeWhere((t) => tagKey(t) == tagKey(tag));
        }
      });

  void _addTyped(String typed) {
    final tags = [..._selected];
    if (!containsTag(tags, typed)) tags.add(typed);
    Navigator.of(context).pop<BulkTagChange>((tags: tags, add: true));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final labelStyle = Theme.of(context).textTheme.labelLarge;
    return AlertDialog(
      title: Text(l10n.bulkTagsTitle(widget.projectCount)),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(l10n.bulkTagsAddLabel, style: labelStyle),
              const SizedBox(height: 8),
              if (widget.suggestions.isNotEmpty) ...[
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final tag in widget.suggestions)
                      FilterChip(
                        key: ValueKey('bulk-add-$tag'),
                        label: Text(tag),
                        visualDensity: VisualDensity.compact,
                        selected: containsTag(_selected, tag),
                        onSelected: (on) => _toggle(tag, on),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
              ],
              // The editor with no chips of its own is exactly "a field that
              // adds a tag, with autocomplete" — here for a tag that is new.
              ProjectTagsEditor(
                tags: const [],
                suggestions: widget.suggestions,
                hintText: l10n.addTagHint,
                removeTooltip: l10n.removeTagTooltip,
                onAdd: _addTyped,
                onRemove: (_) {},
              ),
              const SizedBox(height: 20),
              Text(l10n.bulkTagsRemoveLabel, style: labelStyle),
              const SizedBox(height: 8),
              if (widget.removable.isEmpty)
                Text(
                  l10n.bulkTagsNoneToRemove,
                  style: Theme.of(context).textTheme.bodySmall,
                )
              else
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final tag in widget.removable)
                      InputChip(
                        key: ValueKey('bulk-remove-$tag'),
                        label: Text(tag),
                        visualDensity: VisualDensity.compact,
                        deleteButtonTooltipMessage: l10n.removeTagTooltip(tag),
                        onDeleted: () => Navigator.of(context)
                            .pop<BulkTagChange>((tags: [tag], add: false)),
                      ),
                  ],
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.cancel),
        ),
        FilledButton(
          key: const ValueKey('bulk-add-apply'),
          onPressed: _selected.isEmpty
              ? null
              : () => Navigator.of(context).pop<BulkTagChange>(
                    (tags: List.of(_selected), add: true),
                  ),
          child: Text(l10n.bulkTagsApply),
        ),
      ],
    );
  }
}
