import 'dart:convert';

import 'package:hive_ce/hive.dart';

import '../services/associated_audio/associated_audio_service.dart';
import '../services/associated_audio/audio_index_summary.dart';

/// The audio index for one profile (v3.0.6): each project's full audio
/// report in a lazy box (`<profileId>_audio_index`, read when its page
/// opens) and a small summary per project (`<profileId>_audio_index_summary`,
/// loaded whole for the list's filters).
///
/// **Device-local**: neither Drive sync nor local backup — every path in it
/// names a place on this computer, and it is rebuilt from the files by the
/// next scan. Losing it costs a re-read, never data.
///
/// Also the folders the user added to a project's audio search
/// (`<profileId>_audio_added_folders`, project id → JSON list of paths).
/// Device-local for the same reason: each names a place on this computer's
/// drives. They are the user's choice, so unlike the index they are never
/// dropped by [retainOnly] — a project restored from Recently deleted keeps
/// them.
class AudioIndexStore {
  AudioIndexStore(this.profileId);

  final String profileId;

  static String reportBoxName(String profileId) => '${profileId}_audio_index';
  static String summaryBoxName(String profileId) =>
      '${profileId}_audio_index_summary';
  static String addedFoldersBoxName(String profileId) =>
      '${profileId}_audio_added_folders';

  Future<LazyBox<String>> _reports() async {
    final name = reportBoxName(profileId);
    if (Hive.isBoxOpen(name)) return Hive.lazyBox<String>(name);
    return Hive.openLazyBox<String>(name);
  }

  Future<Box<String>> _summaries() async {
    final name = summaryBoxName(profileId);
    if (Hive.isBoxOpen(name)) return Hive.box<String>(name);
    return Hive.openBox<String>(name);
  }

  Future<Box<String>> _added() async {
    final name = addedFoldersBoxName(profileId);
    if (Hive.isBoxOpen(name)) return Hive.box<String>(name);
    return Hive.openBox<String>(name);
  }

  static List<String> _decodeFolders(String? raw) {
    if (raw == null) return const [];
    try {
      final list = jsonDecode(raw);
      if (list is! List) return const [];
      return [for (final x in list) if (x is String && x.isNotEmpty) x];
    } catch (_) {
      return const [];
    }
  }

  /// The folders the user added to [projectId]'s audio search, in the order
  /// they were added.
  Future<List<String>> addedFolders(String projectId) async =>
      _decodeFolders((await _added()).get(projectId));

  /// Every project's added folders, by project id (only projects with some).
  Future<Map<String, List<String>>> allAddedFolders() async {
    final box = await _added();
    return {
      for (final key in box.keys)
        if (key is String)
          if (_decodeFolders(box.get(key)) case final folders
              when folders.isNotEmpty)
            key: folders,
    };
  }

  /// Replaces [projectId]'s added folders. Duplicates (same path) are kept
  /// once; an empty list removes the entry.
  Future<void> setAddedFolders(String projectId, List<String> folders) async {
    final box = await _added();
    final unique = <String>[];
    for (final f in folders) {
      if (f.isNotEmpty && !unique.contains(f)) unique.add(f);
    }
    if (unique.isEmpty) {
      await box.delete(projectId);
    } else {
      await box.put(projectId, jsonEncode(unique));
    }
  }

  Future<AssociatedAudioReport?> get(String projectId) async {
    final raw = await (await _reports()).get(projectId);
    if (raw == null) return null;
    try {
      return AssociatedAudioReport.fromJson(jsonDecode(raw));
    } catch (_) {
      return null;
    }
  }

  Future<void> put(String projectId, AssociatedAudioReport report) async {
    await (await _reports()).put(projectId, jsonEncode(report.toJson()));
    await (await _summaries())
        .put(projectId, AudioIndexSummary.of(report).encode());
  }

  /// Every project's summary, by project id.
  Future<Map<String, AudioIndexSummary>> summaries() async {
    final box = await _summaries();
    return {
      for (final key in box.keys)
        if (key is String)
          if (AudioIndexSummary.decode(box.get(key)) case final s?) key: s,
    };
  }

  /// Drops everything about projects not in [keep] (deleted ones).
  Future<void> retainOnly(Set<String> keep) async {
    final reports = await _reports();
    final summaries = await _summaries();
    final gone = [
      for (final k in summaries.keys)
        if (k is String && !keep.contains(k)) k,
    ];
    if (gone.isEmpty) return;
    await reports.deleteAll(gone);
    await summaries.deleteAll(gone);
  }
}
