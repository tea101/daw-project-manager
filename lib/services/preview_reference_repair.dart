import 'dart:io';

import 'package:path/path.dart' as p;

import '../models/music_project.dart';
import 'mixdown_detector_service.dart';

/// Repairs preview-song references that automatic detection should never
/// have made.
///
/// Versions up to 3.0.2 let automatic mixdown detection, Auto-Find and the
/// "newer export found" check pick macOS AppleDouble metadata files
/// ("._Song.wav"), because they carry the real file's audio extension. The
/// player then fails with "Failed to set source", and since the file exists,
/// the missing-preview recovery never offers help. They also treated Pro
/// Tools' "Audio Files" folder as a mixdown folder, so a session's preview
/// was a single recorded track.
///
/// No file on disk is read, moved or changed: this only rewrites the
/// catalogue's path fields.
class PreviewReferenceRepair {
  PreviewReferenceRepair._();

  /// Returns [project] repaired, or null when there is nothing to change.
  ///
  /// - Manual preview (`previewSongPath`) on an AppleDouble file: replaced by
  ///   the real file it belongs to ("._Song.wav" -> "Song.wav") when that
  ///   exists, keeping it a manual choice; otherwise cleared, so the project
  ///   falls back to automatic detection. Any other manual preview — missing,
  ///   or anywhere at all — is the user's choice and is left alone.
  /// - Auto-detected preview (`previewSongAutoPath`) on an AppleDouble file, or
  ///   a Pro Tools project's auto preview inside its "Audio Files" folder:
  ///   cleared, so detection runs again with today's rules. Not repointed:
  ///   the real file beside an AppleDouble in "Audio Files" is still a single
  ///   track. Kept when the user listed "Audio Files" as a mixdown folder
  ///   themselves ([userMixdownFolders]).
  /// - Remembered "Keep Current" answer (`ignoredNewerSongPath`) on an
  ///   AppleDouble file: cleared.
  ///
  /// [fileExists] is injectable for tests; it defaults to a disk check.
  static MusicProject? repair(
    MusicProject project, {
    bool Function(String path)? fileExists,
    Iterable<String> userMixdownFolders = const [],
  }) {
    final exists = fileExists ?? (String path) => File(path).existsSync();

    bool isAppleDouble(String? path) =>
        path != null &&
        path.isNotEmpty &&
        MixdownDetectorService.isAppleDoubleFile(path);

    final userListsAudioFiles = userMixdownFolders.any((f) =>
        f.trim().toLowerCase() ==
        MixdownDetectorService.proToolsAudioFilesFolder.toLowerCase());

    bool isProToolsTrack(String? path) =>
        !userListsAudioFiles &&
        path != null &&
        path.isNotEmpty &&
        project.dawType == 'Pro Tools' &&
        p.basename(p.dirname(path)).toLowerCase() ==
            MixdownDetectorService.proToolsAudioFilesFolder.toLowerCase();

    final manualBad = isAppleDouble(project.previewSongPath);
    final autoBad = isAppleDouble(project.previewSongAutoPath) ||
        isProToolsTrack(project.previewSongAutoPath);
    final ignoredBad = isAppleDouble(project.ignoredNewerSongPath);
    if (!manualBad && !autoBad && !ignoredBad) return null;

    var updated = project;

    if (manualBad) {
      final target =
          MixdownDetectorService.appleDoubleTarget(project.previewSongPath!);
      final real = target != null &&
              MixdownDetectorService.isPlayableAudioPath(target) &&
              exists(target)
          ? target
          : null;
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
      updated = updated.copyWith(clearPreviewSongAutoPath: true);
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
    return '${before.displayName}: ${parts.join('; ')}';
  }
}
