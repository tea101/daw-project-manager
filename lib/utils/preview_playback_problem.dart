import 'package:path/path.dart' as p;

import '../services/mixdown_detector_service.dart';

/// Why a preview song couldn't be played — decides what the recovery dialog
/// says. The actions offered are the same for every kind.
enum PreviewPlaybackProblem {
  /// The file isn't there (moved, deleted, drive not mounted).
  missing,

  /// A macOS AppleDouble metadata file ("._Song.wav"), not audio.
  metadataFile,

  /// A format this computer's player can't play (Ogg Vorbis on a Mac).
  unsupportedFormat,

  /// The file is there but the player refused it: damaged, still being
  /// exported, or an encoding the player doesn't support.
  cannotPlay,
}

/// Classifies a failed (or about-to-fail) preview at [path]. Pure apart from
/// [fileExists], which the caller supplies, so it is testable without disk.
PreviewPlaybackProblem classifyPreviewPlaybackProblem(
  String path, {
  required bool fileExists,
}) {
  if (MixdownDetectorService.isAppleDoubleFile(path)) {
    return PreviewPlaybackProblem.metadataFile;
  }
  if (!fileExists) return PreviewPlaybackProblem.missing;
  final ext = p.extension(path).toLowerCase();
  if (!MixdownDetectorService.audioExtensions.contains(ext) ||
      (ext == '.ogg' && !MixdownDetectorService.platformPlaysOgg())) {
    return PreviewPlaybackProblem.unsupportedFormat;
  }
  return PreviewPlaybackProblem.cannotPlay;
}
