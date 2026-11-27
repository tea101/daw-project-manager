import 'package:flutter/foundation.dart';

import '../utils/sync_time.dart';

/// One tag in the user's tag library (Settings > Project tags): a name the
/// tag pickers offer even before any project carries it, and an optional
/// phase rule.
///
/// The library is **global user data**, shared by every profile: it syncs to
/// Drive and goes into local backup, like custom field definitions. Tags on
/// projects stay plain text (`MusicProject.tags`); the library never tags a
/// project by itself.
///
/// Deleting a tag leaves a tombstone ([deletedAt]) — sync and restore merge
/// by union, so an entry that simply vanished would come back.
@immutable
class TagDefinition {
  const TagDefinition({
    required this.id,
    required this.name,
    this.phase,
    this.colorHex,
    this.order = 0,
    this.updatedAt,
    this.deletedAt,
  });

  /// Stable identity (a uuid, or a fixed id for the built-in defaults so two
  /// devices seeding them agree).
  final String id;

  /// The tag text, spelled as it is put on projects.
  final String name;

  /// The phase adding this tag *offers* to move a project to — always with
  /// the user's confirmation. Null: adding the tag keeps the project's phase.
  /// Phases are per profile and matched by name; a rule naming a phase the
  /// active profile doesn't have does nothing.
  final String? phase;

  /// Optional colour, `#RRGGBB`, shown beside the tag in the library and the
  /// pickers.
  final String? colorHex;

  /// Position in the library.
  final int order;

  /// Last edit, for merge: on a same-id collision the newer one wins. Null
  /// (an untouched built-in default) never displaces a timestamped copy.
  final DateTime? updatedAt;

  /// Set when the user deleted the tag from the library.
  final DateTime? deletedAt;

  bool get isDeleted => deletedAt != null;

  TagDefinition copyWith({
    String? name,
    String? phase,
    bool clearPhase = false,
    String? colorHex,
    bool clearColor = false,
    int? order,
    DateTime? updatedAt,
    DateTime? deletedAt,
  }) {
    return TagDefinition(
      id: id,
      name: name ?? this.name,
      phase: clearPhase ? null : (phase ?? this.phase),
      colorHex: clearColor ? null : (colorHex ?? this.colorHex),
      order: order ?? this.order,
      updatedAt: updatedAt ?? this.updatedAt,
      deletedAt: deletedAt ?? this.deletedAt,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'phase': phase,
        'color': colorHex,
        'order': order,
        'updatedAt': syncInstantOrNull(updatedAt),
        'deletedAt': syncInstantOrNull(deletedAt),
      };

  /// Throws on a missing id or name — lists are parsed through
  /// `tagDefinitionsFromJson`, which skips the bad entry.
  factory TagDefinition.fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final name = json['name'];
    if (id is! String || id.isEmpty || name is! String || name.isEmpty) {
      throw const FormatException('tag definition needs an id and a name');
    }
    final phase = json['phase'];
    final color = json['color'];
    return TagDefinition(
      id: id,
      name: name,
      phase: phase is String && phase.isNotEmpty ? phase : null,
      colorHex: color is String && color.isNotEmpty ? color : null,
      order: (json['order'] as num?)?.toInt() ?? 0,
      updatedAt: tryParseSyncInstant(json['updatedAt']),
      deletedAt: tryParseSyncInstant(json['deletedAt']),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is TagDefinition &&
      other.id == id &&
      other.name == name &&
      other.phase == phase &&
      other.colorHex == colorHex &&
      other.order == order &&
      other.updatedAt == updatedAt &&
      other.deletedAt == deletedAt;

  @override
  int get hashCode =>
      Object.hash(id, name, phase, colorHex, order, updatedAt, deletedAt);
}
