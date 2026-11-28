import 'dart:convert';

import 'associated_audio_service.dart';

/// The few facts about a project's audio the projects list filters on,
/// kept apart from the full report so the list never loads every report.
class AudioIndexSummary {
  const AudioIndexSummary({
    required this.confirmed,
    required this.discovered,
    required this.missing,
    required this.hasAdm,
    this.indexedAt,
  });

  factory AudioIndexSummary.of(AssociatedAudioReport report) =>
      AudioIndexSummary(
        confirmed: report.confirmed.where((f) => f.exists).length,
        discovered: report.discovered.where((f) => f.exists).length,
        missing: report.missing.length,
        hasAdm: report.hasAdm,
        indexedAt: report.indexedAt,
      );

  /// Files the session confirms that are here.
  final int confirmed;

  /// Other audio found in the project's folders.
  final int discovered;

  /// Files the session names that aren't here.
  final int missing;

  /// An ADM master is among them (by its header).
  final bool hasAdm;

  final DateTime? indexedAt;

  bool get hasAudio => confirmed + discovered > 0;

  String encode() => jsonEncode({
        'c': confirmed,
        'd': discovered,
        'm': missing,
        if (hasAdm) 'a': true,
        if (indexedAt != null) 't': indexedAt!.toUtc().millisecondsSinceEpoch,
      });

  static AudioIndexSummary? decode(String? raw) {
    if (raw == null) return null;
    try {
      final j = jsonDecode(raw);
      if (j is! Map) return null;
      final t = j['t'];
      return AudioIndexSummary(
        confirmed: j['c'] as int? ?? 0,
        discovered: j['d'] as int? ?? 0,
        missing: j['m'] as int? ?? 0,
        hasAdm: j['a'] == true,
        indexedAt: t is int
            ? DateTime.fromMillisecondsSinceEpoch(t, isUtc: true).toLocal()
            : null,
      );
    } catch (_) {
      return null;
    }
  }
}

/// The projects list's audio filter (v3.0.6), session-only like the others.
enum AudioFilter {
  /// Projects with any audio file associated (confirmed or found).
  hasAudio,

  /// Projects with an ADM master among their audio.
  hasAdm,

  /// Projects whose session names audio that isn't here.
  missingAudio,

  /// Projects not read yet.
  notIndexed,
}

/// Whether a project with [summary] (null: never read) passes [filter].
bool audioFilterMatches(AudioFilter filter, AudioIndexSummary? summary) =>
    switch (filter) {
      AudioFilter.hasAudio => summary?.hasAudio ?? false,
      AudioFilter.hasAdm => summary?.hasAdm ?? false,
      AudioFilter.missingAudio => (summary?.missing ?? 0) > 0,
      AudioFilter.notIndexed => summary == null,
    };
