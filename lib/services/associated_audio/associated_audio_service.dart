import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;

import '../../models/sample_reference.dart';
import '../../utils/audio_format_info.dart';
import '../daw_parsers/wavelab_montage_parser.dart';
import '../sample_pack/project_sample_reader.dart';
import 'audio_roles.dart';

/// Where an audio file in a project's report came from.
enum AudioOrigin {
  /// The session itself refers to it.
  confirmed,

  /// Found in the project's folder; the session wasn't read, or doesn't
  /// refer to it.
  discovered,
}

/// One audio file associated with a project.
class AssociatedAudioFile {
  const AssociatedAudioFile({
    required this.path,
    required this.origin,
    required this.role,
    this.exists = true,
    this.format,
    this.sessionPath,
  });

  /// Where the file is — or, for a missing confirmed file, where the session
  /// last said it was.
  final String path;
  final AudioOrigin origin;
  final AudioRole role;

  /// False for a confirmed file the session names but that isn't here.
  final bool exists;

  /// What the file's header says; null when it couldn't be read (missing,
  /// or a format without a header reader: MP3, AAC).
  final AudioFormatInfo? format;

  /// The session that referred to it (confirmed files only).
  final String? sessionPath;

  String get fileName => p.basename(path);

  AssociatedAudioFile withFormat(AudioFormatInfo? format) => AssociatedAudioFile(
        path: path,
        origin: origin,
        role: format != null && format.isAdm ? AudioRole.admMaster : role,
        exists: exists,
        format: format,
        sessionPath: sessionPath,
      );
}

/// Whether DAW Project Manager can read which audio files a session at
/// [sessionPath] refers to. Pro Tools sessions can't be read yet: their
/// contents are encoded (see PT Peek for those).
bool canReadSessionAudio(String sessionPath) {
  final ext = p.extension(sessionPath).toLowerCase();
  return ext == '.mon' || canReadSampleReferences(sessionPath);
}

/// What was found for a project: its folder, its sessions, and the audio
/// confirmed by them or discovered beside them.
class AssociatedAudioReport {
  const AssociatedAudioReport({
    required this.sessionPaths,
    required this.folders,
    required this.confirmed,
    required this.discovered,
    required this.unreadableSessions,
    this.truncated = false,
  });

  /// The DAW sessions that were read (or tried).
  final List<String> sessionPaths;

  /// The folders searched for other audio. For a version stack, its
  /// versions' folders — never the stack's own path as if it were one.
  final List<String> folders;

  /// Files the sessions refer to, present or not ([AssociatedAudioFile.exists]).
  final List<AssociatedAudioFile> confirmed;

  /// Other audio files in [folders].
  final List<AssociatedAudioFile> discovered;

  /// Sessions whose references couldn't be read: an unsupported format
  /// (Pro Tools) or a damaged file.
  final List<String> unreadableSessions;

  /// The folder search stopped at [kMaxDiscoveredAudio] files.
  final bool truncated;

  List<AssociatedAudioFile> get missing =>
      confirmed.where((f) => !f.exists).toList();
}

/// The most files listed as discovered, so a project in a folder full of
/// sample libraries doesn't list them all.
const int kMaxDiscoveredAudio = 2000;

/// How deep the folder search goes below each project folder.
const int kAudioSearchDepth = 4;

/// Audio extensions searched for, with the dot, lowercase.
const Set<String> kAssociatedAudioExtensions = {
  '.wav', '.wave', '.bwf', '.rf64', '.w64', '.aif', '.aiff', '.aifc',
  '.flac', '.mp3', '.m4a', '.aac', '.ogg', '.caf',
};

/// Folders never searched: DAWs' own backups and caches.
const Set<String> _skippedFolders = {
  'session file backups', 'backup', 'backups', 'auto-backups', 'autosave',
  'auto save', 'history', 'system.mon', 'backup.mon', 'cache', 'wavecache',
  '__macosx',
};

/// Reads which audio files belong to a project, for the project page.
///
/// [sessionPaths] are the DAW sessions to read (one, or a stack's versions);
/// [folders] are searched for any other audio. Nothing is written, moved or
/// renamed. Only what a session needs is read: each session file, then the
/// headers of the audio files found (a few small reads each, never the
/// audio itself).
Future<AssociatedAudioReport> readAssociatedAudio({
  required List<String> sessionPaths,
  required List<String> folders,
}) async {
  final confirmed = <AssociatedAudioFile>[];
  final unreadable = <String>[];
  final seen = <String>{};

  for (final session in sessionPaths) {
    final refs = await _sessionReferences(session);
    if (refs == null) {
      unreadable.add(session);
      continue;
    }
    final base = p.dirname(session);
    for (final ref in refs) {
      final resolved = _resolve(ref.candidates, base);
      final path = resolved ?? _firstAbsolute(ref.candidates, base);
      final key = _key(path);
      if (!seen.add(key)) continue;
      confirmed.add(AssociatedAudioFile(
        path: path,
        origin: AudioOrigin.confirmed,
        role: ref.admSource
            ? AudioRole.admMaster
            : classifyAudioRole(path, projectFolder: base),
        exists: resolved != null,
        sessionPath: session,
      ));
    }
  }

  final found = await Isolate.run(() => _findAudio(folders));
  final discovered = <AssociatedAudioFile>[];
  for (final path in found.paths) {
    if (!seen.add(_key(path))) continue;
    final folder = folders.firstWhere(
      (f) => p.isWithin(f, path) || p.equals(f, p.dirname(path)),
      orElse: () => p.dirname(path),
    );
    discovered.add(AssociatedAudioFile(
      path: path,
      origin: AudioOrigin.discovered,
      role: classifyAudioRole(path, projectFolder: folder),
    ));
  }

  // Headers, all in one background isolate.
  final toRead = [
    for (final f in [...confirmed, ...discovered])
      if (f.exists) f.path,
  ];
  final formats = await Isolate.run(() => {
        for (final path in toRead) path: readAudioFormatSync(path),
      });

  List<AssociatedAudioFile> withFormats(List<AssociatedAudioFile> files) => [
        for (final f in files) f.exists ? f.withFormat(formats[f.path]) : f,
      ];

  return AssociatedAudioReport(
    sessionPaths: sessionPaths,
    folders: folders,
    confirmed: withFormats(confirmed),
    discovered: withFormats(discovered)..sort(_byRoleThenName),
    unreadableSessions: unreadable,
    truncated: found.truncated,
  );
}

int _byRoleThenName(AssociatedAudioFile a, AssociatedAudioFile b) {
  final r = a.role.index.compareTo(b.role.index);
  if (r != 0) return r;
  return a.path.toLowerCase().compareTo(b.path.toLowerCase());
}

String _key(String path) {
  final n = p.normalize(path);
  return Platform.isWindows || Platform.isMacOS ? n.toLowerCase() : n;
}

/// The first candidate that exists: relative ones from [base].
String? _resolve(List<String> candidates, String base) {
  for (final c in candidates) {
    final path = p.isAbsolute(c) ? p.normalize(c) : p.normalize(p.join(base, c));
    try {
      if (File(path).existsSync()) return path;
    } catch (_) {}
  }
  return null;
}

String _firstAbsolute(List<String> candidates, String base) {
  for (final c in candidates) {
    if (p.isAbsolute(c)) return p.normalize(c);
  }
  return p.normalize(p.join(base, candidates.first));
}

typedef _Ref = ({List<String> candidates, bool admSource});

/// The audio references of [session], or null when they can't be read.
Future<List<_Ref>?> _sessionReferences(String session) async {
  final ext = p.extension(session).toLowerCase();
  try {
    if (ext == '.mon') {
      final bytes = await File(session).readAsBytes();
      final parser = WaveLabMontageParser(bytes);
      if (!parser.isMontage) return null;
      return [
        for (final r in parser.readAudioReferences())
          if (r.candidates.isNotEmpty)
            (
              candidates: r.candidates,
              admSource: r.role == WaveLabAudioRole.admSource,
            ),
      ];
    }
    if (canReadSampleReferences(session)) {
      final refs = await readProjectSampleReferences(session);
      return [
        for (final SampleReference r in refs)
          if (r.candidates.isNotEmpty) (candidates: r.candidates, admSource: false),
      ];
    }
  } catch (_) {
    return null;
  }
  return null;
}

({List<String> paths, bool truncated}) _findAudio(List<String> folders) {
  final out = <String>[];
  final seen = <String>{};
  var truncated = false;

  void walk(Directory dir, int depth) {
    if (truncated) return;
    List<FileSystemEntity> entries;
    try {
      entries = dir.listSync(followLinks: false);
    } catch (_) {
      return;
    }
    entries.sort((a, b) => a.path.compareTo(b.path));
    for (final e in entries) {
      final name = p.basename(e.path);
      if (name.startsWith('.')) continue; // hidden, and AppleDouble "._x"
      if (e is File) {
        if (!kAssociatedAudioExtensions.contains(p.extension(name).toLowerCase())) {
          continue;
        }
        if (!seen.add(e.path)) continue;
        if (out.length >= kMaxDiscoveredAudio) {
          truncated = true;
          return;
        }
        out.add(e.path);
      } else if (e is Directory && depth < kAudioSearchDepth) {
        if (_skippedFolders.contains(name.toLowerCase())) continue;
        walk(e, depth + 1);
      }
    }
  }

  for (final folder in folders) {
    final dir = Directory(folder);
    if (dir.existsSync()) walk(dir, 0);
  }
  return (paths: out, truncated: truncated);
}
