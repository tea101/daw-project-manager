import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../generated/l10n/app_localizations.dart';
import '../../models/music_project.dart';
import '../../providers/providers.dart';
import '../../services/mixdown_detector_service.dart';
import '../../utils/mobile_utils.dart';
import '../../utils/preview_playback_problem.dart';
import '../app_snack_bar.dart';

/// Audio extensions offered by every "select a preview song" picker. Single
/// source of truth in [MixdownDetectorService.audioExtensions] so the picker,
/// mixdown auto-detection and drag-and-drop all accept the same set — AIFF
/// (`.aif` / `.aiff`) included.
final List<String> previewAudioExtensions =
    MixdownDetectorService.audioPickerExtensions;

/// What the user chose in [showPreviewSongNotFoundDialog]. A null return from
/// the dialog means Cancel (or a barrier dismiss) — there is deliberately no
/// `cancel` member, so `switch` statements can't forget the null case.
enum PreviewNotFoundAction {
  /// Drop the dead reference and leave the project without a preview song.
  remove,

  /// Drop the dead reference and re-run mixdown auto-detection.
  autoFind,

  /// Pick a replacement file by hand.
  selectNew,
}

/// The "your preview song has gone missing" recovery dialog.
///
/// Shown from three places (dashboard grid, mobile project list, project
/// detail player) that used to each carry their own copy plus a private
/// `_FileNotFoundAction` enum — they drifted, which is how "Find
/// automatically" ended up being addable in only one of them.
///
/// [canAutoFind] hides the auto-detect action. It defaults to whether mixdown
/// scanning works at all on this platform: [MixdownDetectorService] returns
/// null unconditionally on mobile (no filesystem to walk), so offering the
/// button there would only ever produce "nothing found".
///
/// [problem] picks the explanation: a missing file (the default), a macOS
/// "._" metadata file, a format this computer can't play, or a file the player
/// refused. The actions are the same for all of them, and nothing changes
/// until the user picks one.
Future<PreviewNotFoundAction?> showPreviewSongNotFoundDialog(
  BuildContext context, {
  bool? canAutoFind,
  PreviewPlaybackProblem problem = PreviewPlaybackProblem.missing,
}) {
  final l10n = AppLocalizations.of(context)!;
  final showAutoFind = canAutoFind ?? !MobileUtils.isMobile();
  final (title, message) = switch (problem) {
    PreviewPlaybackProblem.missing =>
      (l10n.previewSongFileNotFound, l10n.previewSongFileNotFoundMessage),
    PreviewPlaybackProblem.metadataFile =>
      (l10n.previewCannotPlayTitle, l10n.previewMetadataFileMessage),
    PreviewPlaybackProblem.unsupportedFormat =>
      (l10n.previewCannotPlayTitle, l10n.previewUnsupportedFormatMessage),
    PreviewPlaybackProblem.cannotPlay =>
      (l10n.previewCannotPlayTitle, l10n.previewCannotPlayMessage),
  };
  return showDialog<PreviewNotFoundAction>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(message),
      // Four actions never fit one row at dialog width; stacking them top-down
      // keeps the primary action nearest the content rather than stranded.
      actionsOverflowDirection: VerticalDirection.down,
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: Text(l10n.cancel),
        ),
        OutlinedButton(
          onPressed: () => Navigator.pop(ctx, PreviewNotFoundAction.remove),
          child: Text(l10n.removePreviewSong),
        ),
        if (showAutoFind)
          OutlinedButton(
            onPressed: () => Navigator.pop(ctx, PreviewNotFoundAction.autoFind),
            child: Text(l10n.findPreviewAutomatically),
          ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, PreviewNotFoundAction.selectNew),
          child: Text(l10n.selectNewFile),
        ),
      ],
    ),
  );
}

/// Clears [project]'s dead preview reference, then looks for a replacement in
/// the project's mixdown folders.
///
/// Always persists the cleared reference first, so a miss still leaves the
/// project in a clean state rather than pointing at a file that isn't there.
/// On a hit the found path is stored as `previewSongAutoPath` — the same slot
/// ordinary auto-detection uses, so a later manual pick still wins over it.
///
/// Returns the newly found path, or null when nothing was found.
Future<String?> clearAndAutoFindPreview(
  WidgetRef ref,
  MusicProject project,
) async {
  final repo = await ref.read(repositoryProvider.future);

  final cleared = project.copyWith(
    clearPreviewSongPath: true,
    clearPreviewSongFileName: true,
    clearPreviewSongAutoPath: true,
    // The remembered "don't ask me about this newer file again" answer refers
    // to a file in the folder we just walked away from.
    clearIgnoredNewerSongPath: true,
  );

  final detected = MixdownDetectorService.findLatestMixdown(
    cleared,
    customFolders: ref.read(customMixdownFoldersProvider).value,
    customFoldersByDaw: ref.read(customMixdownFoldersByDawProvider).value,
  );

  await repo.updateProject(
    detected == null
        ? cleared
        : cleared.copyWith(previewSongAutoPath: detected.path),
  );
  ref.invalidate(allProjectsStreamProvider);

  return detected?.path;
}

/// A preview reference successfully repaired by [recoverMissingPreviewSong].
class RecoveredPreview {
  /// The project as it was persisted — callers must play from this rather
  /// than from the stale object they were holding, or the row and the player
  /// end up disagreeing about which file is current.
  final MusicProject project;

  /// The audio file to play.
  final String path;

  const RecoveredPreview(this.project, this.path);
}

/// The whole "preview song is missing" recovery flow: show the dialog, apply
/// whichever action the user picked, persist it, and refresh the projects
/// stream so the dashboard row stops pointing at the dead file.
///
/// Returns null when there is nothing to play afterwards — cancelled, removed,
/// or auto-detection came up empty (a snackbar explains that last one).
Future<RecoveredPreview?> recoverMissingPreviewSong(
  BuildContext context,
  WidgetRef ref,
  MusicProject project, {
  PreviewPlaybackProblem problem = PreviewPlaybackProblem.missing,
}) async {
  final l10n = AppLocalizations.of(context)!;
  final messenger = ScaffoldMessenger.of(context);

  final action = await showPreviewSongNotFoundDialog(context, problem: problem);
  if (action == null) return null;

  // Which slot the dead path lived in decides where a replacement goes: a
  // manual pick must not silently demote itself to an auto-detected one.
  final wasManual = project.previewSongPath?.isNotEmpty == true;

  switch (action) {
    case PreviewNotFoundAction.remove:
      final repo = await ref.read(repositoryProvider.future);
      await repo.updateProject(
        wasManual
            ? project.copyWith(
                clearPreviewSongPath: true,
                clearPreviewSongFileName: true,
              )
            : project.copyWith(clearPreviewSongAutoPath: true),
      );
      ref.invalidate(allProjectsStreamProvider);
      return null;

    case PreviewNotFoundAction.autoFind:
      final found = await clearAndAutoFindPreview(ref, project);
      if (found == null) {
        messenger.showAppSnackBar(
          SnackBar(content: Text(l10n.noPreviewSongFoundAutomatically)),
        );
        return null;
      }
      return RecoveredPreview(
        // clearAndAutoFindPreview clears every preview field before storing
        // the hit, so mirror that here rather than copyWith-ing onto the
        // stale object and resurrecting the old manual path.
        project.copyWith(
          clearPreviewSongPath: true,
          clearPreviewSongFileName: true,
          clearIgnoredNewerSongPath: true,
          previewSongAutoPath: found,
        ),
        found,
      );

    case PreviewNotFoundAction.selectNew:
      final result = await FilePicker.pickFile(
        type: FileType.custom,
        allowedExtensions: previewAudioExtensions,
        dialogTitle: l10n.selectPreviewSong,
      );
      final newPath = result?.path;
      if (newPath == null) return null;

      final repo = await ref.read(repositoryProvider.future);
      final updated = wasManual
          ? project.copyWith(
              previewSongPath: newPath,
              previewSongFileName: p.basename(newPath),
              clearIgnoredNewerSongPath: true,
            )
          : project.copyWith(
              previewSongAutoPath: newPath,
              clearIgnoredNewerSongPath: true,
            );
      await repo.updateProject(updated);
      // Without this the grid row keeps the pre-replacement MusicProject in
      // its `data` cell, so the next play re-opens this very dialog.
      ref.invalidate(allProjectsStreamProvider);
      return RecoveredPreview(updated, newPath);
  }
}

/// Whether [path] is the preview song stored on [project] (manual or
/// auto-detected) — only then may a playback failure offer to change it. A
/// release track or playlist file failing must never rewrite a project's
/// preview.
bool isStoredPreviewOf(MusicProject project, String path) =>
    (project.previewSongPath?.isNotEmpty == true &&
        p.equals(project.previewSongPath!, path)) ||
    (project.previewSongAutoPath != null &&
        p.equals(project.previewSongAutoPath!, path));

/// The recovery offered when the player refuses a preview song, in place of
/// the raw platform error ("PlatformException(DarwinAudioError, Failed to set
/// source)").
///
/// Reads the project as stored (the caller's copy may have the playing path
/// written into `previewSongPath`), and offers the same choices as for a
/// missing file — Find automatically, Select new file, Remove — with an
/// explanation of what went wrong. Nothing changes unless the user picks an
/// action. When [path] isn't the project's stored preview, only a short
/// message is shown and null returned.
Future<RecoveredPreview?> recoverUnplayablePreviewSong(
  BuildContext context,
  WidgetRef ref,
  MusicProject project,
  String path,
) async {
  final l10n = AppLocalizations.of(context)!;
  final messenger = ScaffoldMessenger.of(context);
  final repo = await ref.read(repositoryProvider.future);
  final stored = repo.getById(project.id) ?? project;
  if (!context.mounted) return null;
  if (!isStoredPreviewOf(stored, path)) {
    messenger.showAppSnackBar(
      SnackBar(content: Text(l10n.audioFileCannotPlay)),
    );
    return null;
  }
  final problem = classifyPreviewPlaybackProblem(
    path,
    fileExists: File(path).existsSync(),
  );
  return recoverMissingPreviewSong(context, ref, stored, problem: problem);
}
