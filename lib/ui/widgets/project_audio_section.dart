import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;

import '../../generated/l10n/app_localizations.dart';
import '../../models/music_project.dart';
import '../../providers/providers.dart';
import '../../services/app_audio_focus.dart';
import '../../services/associated_audio/associated_audio_service.dart';
import '../../services/associated_audio/audio_roles.dart';
import '../../services/macos_file_integration.dart';
import '../../services/player_volume_store.dart';
import '../../services/scanner_service.dart';
import '../../services/song_player.dart';
import '../../utils/audio_format_info.dart';
import '../../utils/audio_format_text.dart';
import '../../utils/file_launcher.dart';
import '../../utils/project_file_type.dart';
import '../../utils/track_duration.dart';
import '../app_snack_bar.dart';
import 'semantics_safe.dart';

/// The sessions and folders to look in for [project]'s audio.
///
/// A version stack is a group the app keeps, not a folder on disk: its
/// versions' sessions are read and *their* folders searched — never the
/// stack's own path as if it were a folder of its own. A standalone audio
/// row has neither.
({List<String> sessions, List<String> folders}) audioSourcesFor(
  MusicProject project, {
  List<MusicProject> stackMembers = const [],
}) {
  if (isStandaloneAudioProject(project)) {
    return (sessions: const [], folders: const []);
  }
  if (project.isVirtual) {
    final sessions = [
      for (final m in stackMembers)
        if (!m.isArchived) m.filePath,
    ];
    final folders = {
      for (final s in sessions) ScannerService.projectContainingFolder(s),
    }.toList();
    return (sessions: sessions, folders: folders);
  }
  return (
    sessions: [project.filePath],
    folders: [ScannerService.projectContainingFolder(project.filePath)],
  );
}

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
  AudioFormatInfo? _ownFormat;
  bool _reading = false;
  String? _playingPath;

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
    if (isStandaloneAudioProject(widget.project)) _readOwnFormat();
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

  Future<void> _read() async {
    setState(() => _reading = true);
    final members = widget.project.isVirtual
        ? [
            for (final m in ref.read(allProjectsStreamProvider).value ?? const <MusicProject>[])
              if (m.stackId == widget.project.id) m,
          ]
        : const <MusicProject>[];
    final sources = audioSourcesFor(widget.project, stackMembers: members);
    final report = await readAssociatedAudio(
      sessionPaths: sources.sessions,
      folders: sources.folders,
    );
    if (mounted) {
      setState(() {
        _report = report;
        _reading = false;
      });
    }
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
    // A manual choice: it stays until the user changes it.
    await repo.updateProject(widget.project.copyWith(
      previewSongPath: path,
      previewSongFileName: p.basename(path),
    ));
    ref.invalidate(allProjectsStreamProvider);
    messenger.showAppSnackBar(SnackBar(content: Text(l10n.audioPreviewSet)));
  }

  @override
  Widget build(BuildContext context) {
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
                  OutlinedButton.icon(
                    icon: const Icon(Icons.visibility_outlined, size: 18),
                    label: Text(l10n.openInPtPeek),
                    onPressed: () =>
                        openSessionInPtPeek(context, project.filePath),
                  ),
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
              FilledButton.tonalIcon(
                icon: _reading
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.library_music_outlined, size: 18),
                label: Text(_reading
                    ? l10n.audioFilesReading
                    : report == null
                        ? l10n.audioFilesFind
                        : l10n.audioFilesRefresh),
                onPressed: _reading ? null : _read,
              ),
            ],
          ),
          if (report != null) ...[
            const SizedBox(height: 14),
            if (report.unreadableSessions.isNotEmpty)
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
                l10n.audioDiscoveredTitle(report.discovered.length)),
            if (report.discovered.isEmpty)
              Text(l10n.audioNoneDiscovered, style: dim),
            for (final f in report.discovered) _row(context, f),
            if (report.truncated)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(l10n.audioTruncated(kMaxDiscoveredAudio), style: dim),
              ),
          ],
        ],
      ),
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
    final playable = file.exists && playableInApp(format);
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
                  file.exists
                      ? (details.isEmpty ? p.dirname(file.path) : details)
                      : file.path,
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
            if (!playable)
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

/// Opens [path] in PT Peek from a widget, telling the user when macOS
/// couldn't.
Future<void> openSessionInPtPeek(BuildContext context, String path) async {
  final l10n = AppLocalizations.of(context)!;
  final messenger = ScaffoldMessenger.of(context);
  final ok = await MacFileIntegration.openWith(kPtPeekBundleId, path);
  if (!ok) {
    messenger.showAppSnackBar(SnackBar(content: Text(l10n.ptPeekOpenFailed)));
  }
}
