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
class AudioIndexStore {
  AudioIndexStore(this.profileId);

  final String profileId;

  static String reportBoxName(String profileId) => '${profileId}_audio_index';
  static String summaryBoxName(String profileId) =>
      '${profileId}_audio_index_summary';

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
