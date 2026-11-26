import 'dart:io';

import 'package:path/path.dart' as p;

import '../models/music_project.dart';
import 'mixdown_detector_service.dart';

/// Repairs preview-song references that point at macOS AppleDouble metadata
/// files ("._Song.wav") instead of real audio.
///
/// Versions up to 3.0.2 let automatic mixdown detection, Auto-Find and the
/// "newer export found" check pick such a file, because it carries the real
/// file's audio extension. The player then fails with "Failed to set source",
/// and since the file exists, the missing-preview recovery never offers help.
///
/// Only AppleDouble references are touched. Any other reference — including a
/// manual pick that is missing or in a format the player dislikes — is left
/// exactly as it is. No file on disk is read, moved or changed: this only
/// rewrites the catalogue's path fields.
class PreviewReferenceRepair {
  PreviewReferenceRepair._();

  /// Returns [project] with every AppleDouble preview reference repaired, or
  /// null when it has none (nothing to save).
  ///
  /// - Manual preview (`previewSongPath`): replaced by the real file the
  ///   AppleDouble companion belongs to ("._Song.wav" -> "Song.wav") when that
  ///   file exists, keeping it a manual choice. Otherwise the manual reference
  ///   is cleared so the project falls back to automatic detection.
  /// - Auto-detected preview (`previewSongAutoPath`): same replacement when the
  ///   real file exists; otherwise cleared, so the next scan detects afresh.
  /// - Remembered "Keep Current" answer (`ignoredNewerSongPath`): cleared, since
  ///   it refers to a file that should never have been offered.
  ///
  /// [fileExists] is injectable for tests; it defaults to a disk check.
  static MusicProject? repair(
    MusicProject project, {
    bool Function(String path)? fileExists,
  }) {
    final exists = fileExists ?? (String path) => File(path).existsSync();

    String? genuineFor(String path) {
      final target = MixdownDetectorService.appleDoubleTarget(path);
      if (target == null) return null;
      if (!MixdownDetectorService.isPlayableAudioPath(target)) return null;
      return exists(target) ? target : null;
    }

    bool isBad(String? path) =>
        path != null &&
        path.isNotEmpty &&
        MixdownDetectorService.isAppleDoubleFile(path);

    final manualBad = isBad(project.previewSongPath);
    final autoBad = isBad(project.previewSongAutoPath);
    final ignoredBad = isBad(project.ignoredNewerSongPath);
    if (!manualBad && !autoBad && !ignoredBad) return null;

    var updated = project;

    if (manualBad) {
      final real = genuineFor(project.previewSongPath!);
      updated = real != null
          ? updated.copyWith(
              previewSongPath: real,
              previewSongFileName: p.basename(real),
            )
          : updated.copyWith(
              clearPreviewSongPath: true,
              clearPreviewSongFileName: true,
            );
    }

    if (autoBad) {
      final real = genuineFor(project.previewSongAutoPath!);
      updated = real != null
          ? updated.copyWith(previewSongAutoPath: real)
          : updated.copyWith(clearPreviewSongAutoPath: true);
    }

    if (ignoredBad) {
      updated = updated.copyWith(clearIgnoredNewerSongPath: true);
    }

    return updated;
  }

  /// A dry-run summary for one project, used to report what [repair] would
  /// change before anything is saved.
  static String describe(MusicProject before, MusicProject after) {
    final parts = <String>[];
    void field(String label, String? a, String? b) {
      if (a != b) parts.add('$label: ${a ?? '(none)'} -> ${b ?? '(none)'}');
    }

    field('manual', before.previewSongPath, after.previewSongPath);
    field('auto', before.previewSongAutoPath, after.previewSongAutoPath);
    field('ignored', before.ignoredNewerSongPath, after.ignoredNewerSongPath);
    return '${before.name}: ${parts.join('; ')}';
  }
}
