import 'dart:convert';

import '../models/tag_definition.dart';
import '../utils/project_tags.dart';

/// The `app_settings` box key the tag library is stored under, as a JSON
/// array. Shared by the provider, local backup and Drive sync.
const String tagLibraryStorageKey = 'tagLibrary';

/// The phase the built-in "Previous Version" rule offers.
const String kPreviousVersionPhase = 'Previous Version';

/// The colour a created Previous Version phase gets: grey.
const String kPreviousVersionPhaseColorHex = '#9E9E9E';

/// The phase the Previous Version phase is placed after, when the profile
/// has it.
const String kFinishedPhase = 'Finished';

/// The library before the user has changed anything: "Previous Version",
/// which offers the Previous Version phase, and "Approved Master", which
/// keeps the project's phase (Finished stays a manual decision after QA).
///
/// Fixed ids and no `updatedAt`, so two devices seeding them agree and any
/// real edit wins a merge. Nothing is stored until the user edits the
/// library, and no project is ever tagged by them.
final List<TagDefinition> kDefaultTagLibrary = List.unmodifiable(const [
  TagDefinition(
    id: 'default-previous-version',
    name: 'Previous Version',
    phase: kPreviousVersionPhase,
    order: 0,
  ),
  TagDefinition(
    id: 'default-approved-master',
    name: 'Approved Master',
    order: 1,
  ),
]);

/// Parses a JSON array of tag definitions, skipping unreadable entries.
/// Never throws.
List<TagDefinition> tagDefinitionsFromJson(List? entries) {
  if (entries == null) return const [];
  final tags = <TagDefinition>[];
  for (final entry in entries) {
    if (entry is! Map) continue;
    try {
      tags.add(TagDefinition.fromJson(Map<String, dynamic>.from(entry)));
    } catch (_) {
      continue;
    }
  }
  return tags;
}

/// Reads the stored JSON. A key never written means the defaults; a stored
/// list (even an empty one) is the user's. Never throws.
List<TagDefinition> decodeTagLibrary(String? raw) {
  if (raw == null || raw.isEmpty) return kDefaultTagLibrary;
  try {
    final decoded = jsonDecode(raw);
    return decoded is List ? tagDefinitionsFromJson(decoded) : kDefaultTagLibrary;
  } catch (_) {
    return kDefaultTagLibrary;
  }
}

String encodeTagLibrary(List<TagDefinition> tags) =>
    jsonEncode(tags.map((t) => t.toJson()).toList());

/// Merges [incoming] into [local] by id: union, newer `updatedAt` wins, a
/// copy without a timestamp never displaces one with. Deletions travel as
/// tombstones. Shared by local backup restore and Drive sync.
List<TagDefinition> mergeTagLibraries(
  List<TagDefinition> local,
  List<TagDefinition> incoming,
) {
  final merged = <String, TagDefinition>{for (final t in local) t.id: t};
  for (final tag in incoming) {
    final existing = merged[tag.id];
    if (existing == null || _isNewer(tag, existing)) merged[tag.id] = tag;
  }
  return merged.values.toList();
}

bool _isNewer(TagDefinition incoming, TagDefinition existing) {
  final incomingAt = incoming.updatedAt;
  if (incomingAt == null) return false;
  final existingAt = existing.updatedAt;
  if (existingAt == null) return true;
  return incomingAt.isAfter(existingAt);
}

/// The live library, without tombstones, in order (then by name). Two live
/// entries with the same name (two devices adding "Mixed" offline) show once
/// — the first by order.
List<TagDefinition> activeTagLibrary(List<TagDefinition> all) {
  final live = all.where((t) => !t.isDeleted).toList()
    ..sort((a, b) {
      final byOrder = a.order.compareTo(b.order);
      return byOrder != 0 ? byOrder : tagKey(a.name).compareTo(tagKey(b.name));
    });
  final seen = <String>{};
  return [
    for (final t in live)
      if (seen.add(tagKey(t.name))) t,
  ];
}

/// Every tag a picker offers: the library's, in library order, then any tag
/// in use on a project that the library doesn't hold, alphabetically. The
/// library's spelling wins.
List<String> tagChoices(List<TagDefinition> library, List<String> inUse) {
  final names = [for (final t in activeTagLibrary(library)) t.name];
  final rest = inUse.where((t) => !containsTag(names, t)).toList()
    ..sort((a, b) => tagKey(a).compareTo(tagKey(b)));
  return [...names, ...rest];
}

/// The library's definition for [tag], ignoring case, or null.
TagDefinition? tagDefinitionFor(List<TagDefinition> library, String tag) {
  final key = tagKey(tag);
  for (final t in activeTagLibrary(library)) {
    if (tagKey(t.name) == key) return t;
  }
  return null;
}

/// [phases] with the Previous Version phase added right after Finished (at
/// the end when there is no Finished), or [phases] itself when it is there.
List<String> withPreviousVersionPhase(List<String> phases) {
  if (phases.any((p) => p.toLowerCase() == kPreviousVersionPhase.toLowerCase())) {
    return phases;
  }
  final finished = phases.indexWhere((p) => p == kFinishedPhase);
  final at = finished >= 0 ? finished + 1 : phases.length;
  return [...phases.sublist(0, at), kPreviousVersionPhase, ...phases.sublist(at)];
}
