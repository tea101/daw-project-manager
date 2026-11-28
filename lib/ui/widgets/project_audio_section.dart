import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;

import '../../generated/l10n/app_localizations.dart';
import '../../models/music_project.dart';
import '../../providers/providers.dart';
import '../../services/app_audio_focus.dart';
import '../../services/associated_audio/associated_audio_service.dart';
import '../../services/associated_audio/audio_index_jobs.dart';
import '../../services/associated_audio/audio_roles.dart';
export '../../services/associated_audio/audio_index_jobs.dart' show audioSourcesFor;
import '../../services/macos_file_integration.dart';
import '../../services/player_volume_store.dart';
import '../../services/song_player.dart';
import '../../utils/audio_format_info.dart';
import '../../utils/audio_format_text.dart';
import '../../utils/file_launcher.dart';
import '../../utils/project_file_type.dart';
import '../../utils/track_duration.dart';
import '../app_snack_bar.dart';
import '../external_playback.dart';
import '../../services/external_player.dart';
import 'semantics_safe.dart';

/// Whether a file may be played by the app's own (stereo) player: two
/// channels or fewer, and not an ADM master. Anything else would be
/// downmixed — never done without saying so, so it isn't played here.
bool playableInApp(AudioFormatInfo? format) =>
    format == null || (!format.isAdm && !format.isMultichannel);

/// The project page's "Audio files": which audio belongs to the project,
/// read when asked (a project on a cloud drive downloads what is read).
/// Confirmed files — the ones the session itself names — are kept apart
/// from files merely found in its folder. Nothing is written, moved or
/// renamed; the only change it can make is setting the preview song, and
/// only when asked.
class ProjectAudioSection extends ConsumerStatefulWidget {
  const ProjectAudioSection({super.key, required this.project});

  final MusicProject project;

  @override
  ConsumerState<ProjectAudioSection> createState() =>
      _ProjectAudioSectionState();
}

class _ProjectAudioSectionState extends ConsumerState<ProjectAudioSection> {
  final AudioPlayer _player = newSongPlayer();
  AssociatedAudioReport? _report;
  List<String> _addedFolders = const [];
  AudioFormatInfo? _ownFormat;
  bool _reading = false;
  String? _playingPath;
  late final AudioIndexNotifier _index = ref.read(audioIndexProvider.notifier);

  @override
  void initState() {
    super.initState();
    AppAudioFocus.register(this, () {
      if (_player.state == PlayerState.playing) _player.pause();
    });
    _player.onPlayerStateChanged.listen((state) {
      if (!mounted) return;
      if (state == PlayerState.playing) AppAudioFocus.claim(this);
      if (state != PlayerState.playing && state != PlayerState.paused) {
        setState(() => _playingPath = null);
      }
    });
    _player.onPlayerComplete.listen((_) {
      if (mounted) setState(() => _playingPath = null);
    });
    if (isStandaloneAudioProject(widget.project)) {
      _readOwnFormat();
    } else {
      _loadThenRefresh();
    }
  }

  @override
  void dispose() {
    _player.dispose();
    AppAudioFocus.unregister(this);
    super.dispose();
  }

  Future<void> _readOwnFormat() async {
    final format = await readAudioFormat(widget.project.filePath);
    if (mounted) setState(() => _ownFormat = format);
  }

  /// What the index already knows, at once; then a quiet incremental
  /// refresh (only changed files are read) so the page is current.
  Future<void> _loadThenRefresh() async {
    final cached = await _index.cached(widget.project.id);
    final added = await _index.addedFolders(widget.project.id);
    if (!mounted) return;
    setState(() {
      _report = cached;
      _addedFolders = added;
    });
    await _read(force: false);
  }

  Future<void> _setAddedFolders(List<String> folders) async {
    setState(() {
      _addedFolders = folders;
      _reading = true;
    });
    final report = await _index.setAddedFolders(widget.project, folders);
    if (!mounted) return;
    setState(() {
      if (report != null) _report = report;
      _reading = false;
    });
  }

  Future<void> _addFolder() async {
    final l10n = AppLocalizations.of(context)!;
    final picked = await FilePicker.getDirectoryPath(
      dialogTitle: l10n.audioAddFolderDialogTitle,
    );
    if (picked == null || !mounted || _addedFolders.contains(picked)) return;
    await _setAddedFolders([..._addedFolders, picked]);
  }

  Future<void> _reloadFromCache() async {
    final cached = await _index.cached(widget.project.id);
    if (mounted && cached != null) setState(() => _report = cached);
  }

  Future<void> _read({required bool force}) async {
    if (_reading) return;
    setState(() => _reading = true);
    final report = await _index.indexOne(widget.project, force: force);
    if (!mounted) return;
    setState(() {
      if (report != null) _report = report;
      _reading = false;
    });
  }

  Future<void> _togglePlay(String path) async {
    if (_playingPath == path) {
      await _player.stop();
      setState(() => _playingPath = null);
      return;
    }
    await _player.stop();
    await _player.setVolume(PlayerVolumeStore.current);
    await _player.play(DeviceFileSource(path));
    if (mounted) setState(() => _playingPath = path);
  }

  Future<void> _useAsPreview(String path) async {
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    final repo = await ref.read(repositoryProvider.future);
    // A manual choice: it stays until the user changes it. Saved onto the
    // project as stored now, never the copy this page opened with — that
    // copy would undo any edit made since (a tag, the phase, notes).
    await repo.setPreviewSong(widget.project.id, path);
    ref.invalidate(allProjectsStreamProvider);
    messenger.showAppSnackBar(SnackBar(content: Text(l10n.audioPreviewSet)));
  }

  @override
  Widget build(BuildContext context) {
    // The background index read this project: show what it found.
    ref.listen(audioIndexProvider.select((s) => (s.lastIndexed, s.lastIndexedAt)),
        (_, next) {
      if (next.$1 == widget.project.id && !_reading) _reloadFromCache();
    });
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final project = widget.project;
    final dim = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurface.withValues(alpha: 0.65),
    );
    final ptPeek = Platform.isMacOS &&
        (ref.watch(ptPeekInstalledProvider).value ?? false);

    if (isStandaloneAudioProject(project)) {
      return Padding(
        padding: const EdgeInsets.only(top: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l10n.audioThisFile, style: theme.textTheme.titleSmall),
            const SizedBox(height: 6),
            _row(context, AssociatedAudioFile(
              path: project.filePath,
              origin: AudioOrigin.discovered,
              role: _ownFormat?.isAdm == true ? AudioRole.admMaster : AudioRole.other,
              exists: File(project.filePath).existsSync(),
              format: _ownFormat,
            )),
          ],
        ),
      );
    }

    final sources = audioSourcesFor(project, stackMembers: [
      if (project.isVirtual)
        for (final m in ref.watch(allProjectsStreamProvider).value ?? const <MusicProject>[])
          if (m.stackId == project.id) m,
    ]);
    final report = _report;

    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l10n.audioFilesExplanation, style: dim),
          const SizedBox(height: 10),
          // Where the project is. A stack names its versions' folders and
          // says it is not one itself.
          if (project.isVirtual)
            _labelled(context, l10n.audioStackFolders(sources.sessions.length),
                sources.folders)
          else ...[
            _labelled(context, l10n.audioProjectFolder, sources.folders),
            _labelled(context, l10n.audioSession, [project.filePath]),
          ],
          if (!project.isVirtual && ptPeek && ptPeekHandles(project.filePath))
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Wrap(
                spacing: 8,
                children: [
                  // Quick Look only: "Open in PT Peek" was removed — PT Peek
                  // was handed the session and showed nothing.
                  OutlinedButton.icon(
                    icon: const Icon(Icons.preview_outlined, size: 18),
                    label: Text(l10n.quickLookSession),
                    onPressed: () =>
                        MacFileIntegration.quickLook([project.filePath]),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 10),
          Row(
            children: [
              if (_reading)
                const Padding(
                  padding: EdgeInsets.only(right: 8),
                  child: SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              Expanded(
                child: Text(
                  _reading
                      ? (report == null
                          ? l10n.audioFilesReadingFirst
                          : l10n.audioFilesReading)
                      : report?.indexedAt == null
                          ? ''
                          : l10n.audioIndexedAt(DateFormat.yMMMd(
                                  Localizations.localeOf(context).toString())
                              .add_Hm()
                              .format(report!.indexedAt!)),
                  style: dim,
                ),
              ),
              TextButton.icon(
                icon: const Icon(Icons.refresh, size: 18),
                label: Text(l10n.audioFilesRefresh),
                onPressed: _reading ? null : () => _read(force: true),
              ),
            ],
          ),
          if (report != null && report.offlineFolders.isNotEmpty)
            _notice(context, l10n.audioOfflineFolders),
          if (report != null && report.cloudOnlySessions.isNotEmpty)
            _notice(context, l10n.audioCloudOnlySessions),
          if (report != null) ...[
            const SizedBox(height: 14),
            if (sessionAudioLivesElsewhere(report))
              _notice(
                context,
                report.unreadableSessions.any(ptPeekHandles) && ptPeek
                    ? '${l10n.audioNoAudioInSessionFolder} ${l10n.audioNoAudioInSessionFolderPtPeek}'
                    : '${l10n.audioNoAudioInSessionFolder} ${l10n.audioNoAudioInSessionFolderAdd}',
              )
            else if (report.unreadableSessions.isNotEmpty)
              _notice(
                context,
                report.unreadableSessions.any(ptPeekHandles) && ptPeek
                    ? '${l10n.audioSessionUnreadable} ${l10n.audioSessionUnreadablePtPeek}'
                    : l10n.audioSessionUnreadable,
              ),
            if (report.sessionPaths.any(canReadSessionAudio)) ...[
              _groupTitle(context, Icons.verified_outlined,
                  l10n.audioConfirmedTitle(report.confirmed.where((f) => f.exists).length)),
              if (report.confirmed.where((f) => f.exists).isEmpty)
                Text(l10n.audioNoneConfirmed, style: dim),
              for (final f in report.confirmed.where((f) => f.exists))
                _row(context, f),
              if (report.missing.isNotEmpty) ...[
                const SizedBox(height: 8),
                _groupTitle(context, Icons.link_off,
                    l10n.audioMissingTitle(report.missing.length),
                    color: theme.colorScheme.error),
                for (final f in report.missing) _row(context, f),
              ],
              const SizedBox(height: 12),
            ],
            _groupTitle(context, Icons.folder_outlined,
                l10n.audioDiscoveredTitle(report.inProjectFolders.length)),
            if (report.inProjectFolders.isEmpty)
              Text(l10n.audioNoneDiscovered, style: dim),
            for (final f in report.inProjectFolders) _row(context, f),
            // Folders the user added: their own heading, their own files.
            if (_addedFolders.isNotEmpty) ...[
              const SizedBox(height: 12),
              _groupTitle(context, Icons.create_new_folder_outlined,
                  l10n.audioFoundInAddedTitle(report.inAddedFolders.length)),
              if (report.inAddedFolders.isEmpty)
                Text(l10n.audioNoneInAdded, style: dim),
              for (final f in report.inAddedFolders) _row(context, f),
            ],
            if (report.truncated)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(l10n.audioTruncated(kMaxDiscoveredAudio), style: dim),
              ),
          ],
          const SizedBox(height: 16),
          _addedFoldersEditor(context),
        ],
      ),
    );
  }

  /// The folders the user added to this project's search, each removable,
  /// and the button to add one.
  Widget _addedFoldersEditor(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final dim = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurface.withValues(alpha: 0.65),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(l10n.audioAddedFoldersTitle, style: theme.textTheme.titleSmall),
        const SizedBox(height: 2),
        Text(l10n.audioAddedFoldersExplanation, style: dim),
        const SizedBox(height: 6),
        for (final folder in _addedFolders)
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              const Icon(Icons.folder_outlined, size: 16),
              const SizedBox(width: 6),
              Expanded(
                child: SelectableText(folder, style: theme.textTheme.bodySmall),
              ),
              IconButton(
                tooltip: l10n.audioRemoveAddedFolder,
                icon: const Icon(Icons.close, size: 16),
                onPressed: _reading
                    ? null
                    : () => _setAddedFolders(
                        [for (final f in _addedFolders) if (f != folder) f]),
              ),
            ],
          ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            icon: const Icon(Icons.create_new_folder_outlined, size: 18),
            label: Text(l10n.audioAddFolder),
            onPressed: _reading ? null : _addFolder,
          ),
        ),
      ],
    );
  }

  Widget _labelled(BuildContext context, String label, List<String> paths) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 140,
            child: Text(label, style: theme.textTheme.labelMedium),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final path in paths)
                  SelectableText(path, style: theme.textTheme.bodySmall),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _notice(BuildContext context, String text) {
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: theme.colorScheme.secondaryContainer.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.info_outline, size: 18),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: theme.textTheme.bodySmall)),
        ],
      ),
    );
  }

  Widget _groupTitle(BuildContext context, IconData icon, String text,
      {Color? color}) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          Icon(icon, size: 18, color: color ?? theme.colorScheme.primary),
          const SizedBox(width: 6),
          Text(text, style: theme.textTheme.titleSmall?.copyWith(color: color)),
        ],
      ),
    );
  }

  String? _roleLabel(AppLocalizations l10n, AudioRole role) => switch (role) {
        AudioRole.admMaster => l10n.audioRoleAdm,
        AudioRole.stem => l10n.audioRoleStem,
        AudioRole.sessionClip => l10n.audioRoleSessionClip,
        AudioRole.master => l10n.audioRoleMaster,
        AudioRole.mix => l10n.audioRoleMix,
        AudioRole.bounce => l10n.audioRoleBounce,
        AudioRole.render => l10n.audioRoleRender,
        AudioRole.other => null,
      };

  Widget _row(BuildContext context, AssociatedAudioFile file) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final format = file.format;
    final role = _roleLabel(l10n, file.role);
    final mono = multiMonoPart(file.path);
    final details = [
      if (format != null) ...[
        if (audioFormatSummary(format).isNotEmpty) audioFormatSummary(format),
        if (audioFormatText(format.sampleRate, format.bitsPerSample,
                l10n.inspectorBitDepth)
            case final rate?)
          rate,
        if (format.duration != null) formatTrackDuration(format.duration!),
      ],
      if (mono != null) l10n.audioMultiMono(mono.channel),
    ].join(' · ');
    final playable = file.exists && !file.cloudOnly && playableInApp(format);
    final whyNot = format == null
        ? null
        : format.isAdm
            ? l10n.audioNotPlayableAdm
            : format.isMultichannel
                ? l10n.audioNotPlayableMultichannel(format.channels ?? 0)
                : null;
    final isPreview = widget.project.previewSongPath == file.path;
    final playing = _playingPath == file.path;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(
            width: 40,
            child: !file.exists
                ? const Icon(Icons.help_outline, size: 18)
                : file.cloudOnly
                    ? StandaloneTooltip(
                        message: l10n.audioCloudOnlyFile,
                        child: const Icon(Icons.cloud_outlined, size: 20),
                      )
                    : playable
                    ? IconButton(
                        tooltip: playing ? l10n.audioStop : l10n.audioPlay,
                        icon: Icon(playing ? Icons.stop : Icons.play_arrow),
                        onPressed: () => _togglePlay(file.path),
                      )
                    : StandaloneTooltip(
                        message: whyNot ?? '',
                        child: Icon(
                          format?.isAdm == true
                              ? Icons.surround_sound_outlined
                              : Icons.speaker_group_outlined,
                          size: 20,
                          color: theme.colorScheme.tertiary,
                        ),
                      ),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        file.fileName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (role != null) ...[
                      const SizedBox(width: 6),
                      _chip(context, role,
                          strong: file.role == AudioRole.admMaster),
                    ],
                    if (isPreview) ...[
                      const SizedBox(width: 6),
                      _chip(context, l10n.audioIsPreview),
                    ],
                  ],
                ),
                Text(
                  !file.exists
                      ? file.path
                      : file.cloudOnly
                          ? l10n.audioCloudOnlyFile
                          : (details.isEmpty ? p.dirname(file.path) : details),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
          if (file.exists) ...[
            if (playable && !isPreview && !isStandaloneAudioProject(widget.project))
              IconButton(
                tooltip: l10n.audioUseAsPreview,
                icon: const Icon(Icons.push_pin_outlined, size: 18),
                onPressed: () => _useAsPreview(file.path),
              ),
            // Multichannel and ADM files: never downmixed, never played as
            // silence — they go to the user's external player (or are
            // dragged into one).
            if (!playable && !file.cloudOnly && needsExternalPlayer(format)) ...[
              Builder(builder: (context) {
                final shown = externalPlayerShownFor(
                  format,
                  installed:
                      ref.watch(installedExternalPlayersProvider).value ??
                          const {},
                  preference: ref.watch(externalPlayerPreferenceProvider),
                );
                return IconButton(
                  tooltip: shown == null
                      ? l10n.externalPlayerOpenInPlayer
                      : l10n.externalPlayerOpenIn(shown.displayName),
                  icon: const Icon(Icons.headphones_outlined, size: 18),
                  onPressed: () =>
                      openInExternalPlayer(context, ref, file.path, format),
                );
              }),
              ExternalPlayerDragHandle(path: file.path),
            ] else if (!playable && !file.cloudOnly)
              IconButton(
                tooltip: l10n.audioOpenWithDefault,
                icon: const Icon(Icons.open_in_new, size: 18),
                onPressed: () => FileLauncher.openFile(file.path),
              ),
            IconButton(
              tooltip: l10n.revealInFolder,
              icon: const Icon(Icons.folder_open, size: 18),
              onPressed: () => FileLauncher.openFolder(p.dirname(file.path)),
            ),
          ],
        ],
      ),
    );
  }

  Widget _chip(BuildContext context, String text, {bool strong = false}) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: strong
            ? scheme.tertiaryContainer
            : scheme.secondaryContainer.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11,
          color: strong ? scheme.onTertiaryContainer : scheme.onSecondaryContainer,
        ),
      ),
    );
  }
}
