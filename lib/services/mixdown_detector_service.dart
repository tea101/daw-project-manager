import 'dart:io';
import 'package:path/path.dart' as p;
import '../models/music_project.dart';
import '../utils/audio_format_info.dart';
import '../utils/mobile_utils.dart';
import 'associated_audio/audio_roles.dart';
import 'auto_preview_rules.dart';

/// Locates the most recently modified audio file in a project's mixdown/bounce
/// folder, for use as a fallback preview when no song has been set manually.
///
/// Desktop-only — always returns null on mobile.
class MixdownDetectorService {
  MixdownDetectorService._();

  /// Audio file extensions (leading dot, lowercase) the app treats as a
  /// playable "song": mixdown auto-detection, the preview-song picker,
  /// drag-and-drop, release-file typing, waveform rendering. Every one of
  /// these decodes on macOS/iOS via AVFoundation and on desktop via the
  /// bundled ffmpeg fallback — including AIFF (`.aif` / `.aiff`).
  static const Set<String> audioExtensions = {
    '.wav', '.mp3', '.flac', '.aif', '.aiff', '.aac', '.m4a', '.ogg',
  };

  /// [audioExtensions] without the leading dot, for
  /// `FilePicker.allowedExtensions` which wants bare extensions.
  static final List<String> audioPickerExtensions = audioExtensions
      .map((e) => e.substring(1))
      .toList(growable: false);

  // Matches this app's own Drive-download filenames — "<uuid>_preview.<ext>" —
  // written by GoogleDriveSyncService.downloadPreviewSongFile into a single
  // "preview_songs" cache directory shared by every project. That directory is
  // not a per-project export folder, so a "same folder" scan must never run
  // against it: it would surface other projects' downloaded previews as false
  // "newer export found" hits.
  static final RegExp _driveDownloadFileRe = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}_preview\.',
    caseSensitive: false,
  );

  /// Per-DAW folder names to check, in priority order.
  /// Values match the `dawType` strings produced by metadata_extractor.dart.
  /// Exposed publicly so settings UI can explain the defaults to the user.
  static const Map<String, List<String>> dawFolders = {
    'Ableton Live':  ['Bounces', 'Mixdown', 'Exports', 'Export'],
    'Logic Pro':     ['Bounces'],          // inside .logicx bundle (handled separately)
    'Cubase':        ['Mixdown'],
    'Nuendo':        ['Mixdown'],
    'Studio One':    ['Mixdown', 'Mix', 'Exports'],
    // Not 'Audio Files': that is where Pro Tools keeps recorded and imported
    // clips, so "newest file" there is a single track (a tom, a vocal take),
    // never a mix. It was a default up to 3.0.2.
    'Pro Tools':     ['Bounced Files', 'Bounce'],
    'Reaper':        ['Renders', 'Render', 'Mixdown'],
    'FL Studio':     ['Mixdown', 'Exports', 'Export'],
    'Bitwig Studio': ['bounce', 'Bounces', 'Mixdown', 'Exports'],
    'Maschine':      ['Exports', 'Export', 'Mixdown'],
    'Waveform':      ['Exports', 'Mixdown'],
    'Sonar':         ['Mixdown', 'Audio'],
    'LUNA':          ['Exported Files'],
  };

  /// Checked for any DAW not in the map above, and appended as final fallbacks
  /// for DAWs that are in the map (covers custom folder setups).
  /// Exposed publicly so settings UI can explain the defaults to the user.
  static const List<String> fallbackFolders = [
    'Mixdown', 'Bounces', 'Renders', 'Exports',
    'bounce',  'Render',  'Export',
  ];

  /// Key used in [findLatestMixdown]'s `customFoldersByDaw` map for projects
  /// whose `dawType` is null or not one of [dawFolders]' keys — mirrors how
  /// those projects already fall back to [fallbackFolders].
  static const String otherDawKey = '_other';

  /// Pro Tools' folder of recorded and imported clips. An automatic preview
  /// found there (before 3.0.3 it was a default mixdown folder) is a single
  /// track, not a mix.
  static const String proToolsAudioFilesFolder = 'Audio Files';

  /// True for a macOS AppleDouble metadata file ("._Song.wav"). macOS writes
  /// one beside every file it copies to a non-Apple volume (exFAT, FAT32,
  /// network shares). It carries the real file's audio extension but holds
  /// only a few KB of Finder metadata, so it can't be played: AVFoundation
  /// rejects it with "Failed to set source".
  static bool isAppleDoubleFile(String path) => p.basename(path).startsWith('._');

  /// Whether [path] names something the app may offer as a preview song: an
  /// [audioExtensions] file that is not an AppleDouble companion.
  static bool isPlayableAudioPath(String path) =>
      !isAppleDoubleFile(path) &&
      audioExtensions.contains(p.extension(path).toLowerCase());

  /// Whether this platform's player can play Ogg Vorbis. macOS and iOS play
  /// through AVFoundation, which can't, so an `.ogg` there fails with the same
  /// "Failed to set source" as an AppleDouble file. Overridable in tests.
  static bool Function() platformPlaysOgg =
      () => !(Platform.isMacOS || Platform.isIOS);

  /// Whether automatic detection (scan, Auto-Find, "newer export found") may
  /// offer [path]: playable audio, and not a format this platform can't play.
  /// A file the user picks by hand is still accepted ([isPlayableAudioPath]).
  static bool isAutoDetectableAudioPath(String path) =>
      isPlayableAudioPath(path) &&
      (p.extension(path).toLowerCase() != '.ogg' || platformPlaysOgg());

  /// The real file an AppleDouble companion describes: "dir/._Song.wav" ->
  /// "dir/Song.wav". Returns null when [path] is not an AppleDouble file.
  static String? appleDoubleTarget(String path) {
    if (!isAppleDoubleFile(path)) return null;
    final name = p.basename(path).substring(2);
    if (name.isEmpty) return null;
    return p.join(p.dirname(path), name);
  }

  /// Auto-detectable audio files directly inside [dir], or an empty list when the
  /// folder can't be read (permissions, a drive just unmounted) — a read
  /// error must never abort detection for every other project.
  static List<File> _audioFilesIn(Directory dir) {
    try {
      return dir
          .listSync()
          .whereType<File>()
          .where((f) => isAutoDetectableAudioPath(f.path))
          .toList();
    } on FileSystemException {
      return const [];
    }
  }

  static DateTime _modified(File f) {
    try {
      return f.lastModifiedSync();
    } on FileSystemException {
      return DateTime.fromMillisecondsSinceEpoch(0);
    }
  }

  /// Returns the most recently modified audio file found in the project's
  /// mixdown folder, or null if nothing is found.
  ///
  /// [customFolders] are optional user-defined subfolder names, checked
  /// first and in order, before the DAW-specific and generic defaults.
  /// [customFoldersByDaw] are optional user-defined additions scoped to a
  /// single DAW (keyed by the same strings as [dawFolders], or
  /// [otherDawKey]) — checked after [customFolders] but before that DAW's
  /// hardcoded defaults, so a user addition takes priority over the guess.
  static File? findLatestMixdown(
    MusicProject project, {
    List<String>? customFolders,
    Map<String, List<String>>? customFoldersByDaw,
  }) {
    if (MobileUtils.isMobile()) return null;
    if (project.filePath.isEmpty) return null;
    // A folder holding several sessions shares its bounce folder between
    // them: there, only a file named after this session will do (v3.0.6).
    final shared = sessionFolderIsShared(project.filePath);

    for (final dir in _candidateDirs(
      project,
      customFolders: customFolders,
      customFoldersByDaw: customFoldersByDaw,
    )) {
      if (!dir.existsSync()) continue;

      final files = _audioFilesIn(dir);
      if (files.isEmpty) continue;

      files.sort((a, b) => _modified(b).compareTo(_modified(a)));
      // Newest first, skipping what must never be a preview by itself:
      // stems, a session's own clips, ADM masters and anything with more
      // than two channels (the preview player would downmix it unasked).
      // A folder the user listed as their mixdown folder is theirs to
      // name — "Audio Files" included — so only the header rules and stems
      // apply there.
      final userListed = _userListedDirs(project,
              customFolders: customFolders,
              customFoldersByDaw: customFoldersByDaw)
          .contains(p.normalize(dir.path));
      final projectDir = File(project.filePath).parent.path;
      for (final file in files) {
        final format = readFormat(file.path);
        if (mayAutoSelect(file.path,
                projectFolder: projectDir,
                userListedFolder: userListed,
                format: format) &&
            // Never a part of a mix (an instrument group, one channel of a
            // split, a mono file); in a folder shared by several sessions,
            // only a file reliably named after this one (v3.0.6).
            autoPreviewFitsSession(file.path, project.filePath,
                sharedFolder: shared, format: format)) {
          return file;
        }
      }
    }

    return null;
  }

  /// Every folder name automatic detection treats as [project]'s mixdown
  /// folder: the user's, the DAW's and the generic ones (v3.0.6, for
  /// [isInSessionBounceFolder]).
  static List<String> bounceFolderNamesFor(
    String? dawType, {
    Iterable<String> userFolders = const [],
  }) =>
      [
        ...userFolders,
        ...?dawFolders[dawType],
        ...fallbackFolders,
        if (dawType == 'Logic Pro') 'Bounces',
        'Exported Files',
      ];

  /// Whether the folder [sessionPath] sits in holds other sessions of the
  /// same kind (same extension; AppleDouble companions don't count), so
  /// its bounce folder is shared. False when the folder can't be read.
  /// Overridable in tests.
  static bool Function(String sessionPath) sessionFolderIsShared =
      _sessionFolderIsShared;

  static bool _sessionFolderIsShared(String sessionPath) {
    final ext = p.extension(sessionPath).toLowerCase();
    if (ext.isEmpty) return false;
    try {
      var count = 0;
      for (final entity in Directory(p.dirname(sessionPath)).listSync()) {
        if (entity is! File) continue;
        final name = p.basename(entity.path);
        if (name.startsWith('._') || name.startsWith('.')) continue;
        if (p.extension(name).toLowerCase() != ext) continue;
        if (++count > 1) return true;
      }
    } on FileSystemException {
      return false;
    }
    return false;
  }

  /// Reads a candidate's header; overridable in tests.
  static AudioFormatInfo? Function(String path) readFormat = readAudioFormatSync;

  /// Whether automatic detection may pick [path] as a preview: not a stem,
  /// a session clip, an ADM master or a multichannel file
  /// ([autoPreviewRejection]). Reads the file's header — a few small reads,
  /// only for a file that is about to be offered for playback anyway.
  static bool mayAutoSelect(
    String path, {
    String? projectFolder,
    bool userListedFolder = false,
    AudioFormatInfo? format,
  }) {
    final rejection = autoPreviewRejection(
      path,
      projectFolder: projectFolder,
      format: format ?? readFormat(path),
    );
    if (rejection == null) return true;
    return userListedFolder && rejection == AutoPreviewRejection.sessionClip;
  }

  static Set<String> _userListedDirs(
    MusicProject project, {
    List<String>? customFolders,
    Map<String, List<String>>? customFoldersByDaw,
  }) {
    final projectDir = File(project.filePath).parent.path;
    return {
      for (final name in [
        ...?customFolders,
        ...?customFoldersByDaw?[project.dawType ?? otherDawKey],
      ])
        if (name.isNotEmpty) p.normalize(p.join(projectDir, name)),
    };
  }

  /// Returns the newest audio file in the same directory as [currentPath] if it
  /// is strictly newer than [currentPath] itself and is a different file.
  /// Returns null if [currentPath] is already the newest, doesn't exist, is on
  /// mobile, or lives in the shared Drive-download preview cache (that folder
  /// holds every project's downloaded preview, not just this project's exports).
  ///
  /// [ignoredPath] is a path the user has previously rejected ("Keep Current").
  /// If the newest file matches it, the prompt is suppressed until a genuinely
  /// different (even newer) file appears.
  static File? findNewerFileInSameFolder(String currentPath, {String? ignoredPath}) {
    if (MobileUtils.isMobile()) return null;
    if (_driveDownloadFileRe.hasMatch(p.basename(currentPath))) return null;
    final current = File(currentPath);
    if (!current.existsSync()) return null;
    final currentModified = _modified(current);
    final files = _audioFilesIn(current.parent);
    if (files.isEmpty) return null;
    files.sort((a, b) => _modified(b).compareTo(_modified(a)));
    final newest = files.first;
    if (p.equals(newest.path, current.path)) return null;
    if (ignoredPath != null && p.equals(newest.path, ignoredPath)) return null;
    // An AppleDouble "current" is not a real preview (see
    // PreviewReferenceRepair) — any genuine file beats it.
    if (isAppleDoubleFile(current.path)) return newest;
    if (_modified(newest).isAfter(currentModified)) return newest;
    return null;
  }

  static List<Directory> _candidateDirs(
    MusicProject project, {
    List<String>? customFolders,
    Map<String, List<String>>? customFoldersByDaw,
  }) {
    final projectFile = File(project.filePath);
    final projectDir = projectFile.parent.path;
    final dirs = <String>[];

    // User-defined folders are checked first, in the given order
    if (customFolders != null) {
      for (final name in customFolders) {
        if (name.isEmpty) continue;
        dirs.add(p.join(projectDir, name));
      }
    }

    // User-defined additions scoped to this project's DAW, checked next —
    // ahead of that DAW's hardcoded defaults but after the fully-global list.
    final perDawFolders =
        customFoldersByDaw?[project.dawType ?? otherDawKey];
    if (perDawFolders != null) {
      for (final name in perDawFolders) {
        if (name.isEmpty) continue;
        dirs.add(p.join(projectDir, name));
      }
    }

    // Logic Pro: .logicx is a macOS bundle — Bounces lives inside it
    if (project.dawType == 'Logic Pro' &&
        project.filePath.toLowerCase().endsWith('.logicx')) {
      dirs.add(p.join(project.filePath, 'Bounces'));
    }

    // LUNA: .luna is a package — Exported Files (mixdowns) lives inside it.
    // (The "Rendered" folder holds frozen VSTi/track renders, not mixdowns,
    // so it's deliberately not treated as a preview source.)
    if (project.dawType == 'LUNA' &&
        project.filePath.toLowerCase().endsWith('.luna')) {
      dirs.add(p.join(project.filePath, 'Exported Files'));
    }

    // DAW-specific folders
    final dawSpecific = project.dawType != null
        ? (dawFolders[project.dawType!] ?? fallbackFolders)
        : fallbackFolders;

    for (final name in dawSpecific) {
      dirs.add(p.join(projectDir, name));
    }

    // Always append generic fallbacks (deduplicated)
    for (final name in fallbackFolders) {
      final path = p.join(projectDir, name);
      if (!dirs.contains(path)) dirs.add(path);
    }

    return dirs.map(Directory.new).toList();
  }
}
