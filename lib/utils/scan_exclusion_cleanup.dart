import '../models/music_project.dart';
import '../services/scanner_service.dart';

/// What a rescan offers to tidy away: catalogued entries whose file the
/// scanner now skips — a WaveLab automatic backup (inside `Backup.mon`) or a
/// macOS AppleDouble file (`._Song.ptx`). Earlier versions listed them as
/// projects of their own.
class ScanExclusionCleanup {
  /// Entries to offer for removal (moved to Recently deleted on confirm).
  final List<MusicProject> removable;

  /// Matching entries left alone because a release uses them: removing one
  /// would silently drop a track from that release.
  final List<MusicProject> keptForReleases;

  const ScanExclusionCleanup({
    required this.removable,
    required this.keptForReleases,
  });

  bool get isEmpty => removable.isEmpty && keptForReleases.isEmpty;
}

/// Finds the entries in [projects] that match the WaveLab-backup and
/// AppleDouble exclusion rules ([ScannerService.isNewlyExcludedPath]).
///
/// Only real scanned entries are considered — never a version stack (its path
/// is a folder) or an archived project (its path is the archive) — and
/// anything in [releaseProtectedIds] is reported separately, never removed.
///
/// Pure: reads paths only, never the disk. Nothing here touches files; the
/// caller moves confirmed entries to Recently deleted, which keeps their
/// notes, phases and history restorable for 30 days.
ScanExclusionCleanup findScanExclusionCleanup(
  Iterable<MusicProject> projects,
  Set<String> releaseProtectedIds,
) {
  final removable = <MusicProject>[];
  final kept = <MusicProject>[];
  for (final project in projects) {
    if (!project.isMissingFileCandidate) continue;
    if (!ScannerService.isNewlyExcludedPath(project.filePath)) continue;
    if (releaseProtectedIds.contains(project.id)) {
      kept.add(project);
    } else {
      removable.add(project);
    }
  }
  return ScanExclusionCleanup(removable: removable, keptForReleases: kept);
}
