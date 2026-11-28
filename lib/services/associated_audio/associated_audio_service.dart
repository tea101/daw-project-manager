import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;

import '../../utils/audio_format_info.dart';
import '../../utils/cloud_file.dart';
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
    this.sizeBytes,
    this.modifiedMs,
    this.cloudOnly = false,
  });

  /// Where the file is — or, for a missing confirmed file, where the session
  /// last said it was.
  final String path;
  final AudioOrigin origin;
  final AudioRole role;

  /// False for a confirmed file the session names but that isn't here.
  final bool exists;

  /// What the file's header says; null when it couldn't be read (missing,
  /// cloud-only, or a format without a header reader: MP3, AAC).
  final AudioFormatInfo? format;

  /// The session that referred to it (confirmed files only).
  final String? sessionPath;

  /// Size and modification time when it was last looked at: an unchanged
  /// file is never opened again.
  final int? sizeBytes;
  final int? modifiedMs;

  /// Its contents are with a cloud provider, not on this computer: its
  /// header was not read, so as not to download it.
  final bool cloudOnly;

  String get fileName => p.basename(path);

  AssociatedAudioFile copyWith({
    AudioOrigin? origin,
    AudioRole? role,
    String? sessionPath,
  }) =>
      AssociatedAudioFile(
        path: path,
        origin: origin ?? this.origin,
        role: role ?? this.role,
        exists: exists,
        format: format,
        sessionPath: sessionPath ?? this.sessionPath,
        sizeBytes: sizeBytes,
        modifiedMs: modifiedMs,
        cloudOnly: cloudOnly,
      );

  Map<String, Object?> toJson() => {
        'p': path,
        'o': origin.name,
        'r': role.name,
        if (!exists) 'x': false,
        if (format != null) 'f': format!.toJson(),
        if (sessionPath != null) 's': sessionPath,
        if (sizeBytes != null) 'z': sizeBytes,
        if (modifiedMs != null) 'm': modifiedMs,
        if (cloudOnly) 'c': true,
      };

  static AssociatedAudioFile? fromJson(Object? json) {
    if (json is! Map || json['p'] is! String) return null;
    AudioOrigin origin = AudioOrigin.discovered;
    for (final o in AudioOrigin.values) {
      if (o.name == json['o']) origin = o;
    }
    AudioRole role = AudioRole.other;
    for (final r in AudioRole.values) {
      if (r.name == json['r']) role = r;
    }
    return AssociatedAudioFile(
      path: json['p'] as String,
      origin: origin,
      role: role,
      exists: json['x'] != false,
      format: AudioFormatInfo.fromJson(json['f']),
      sessionPath: json['s'] as String?,
      sizeBytes: json['z'] as int?,
      modifiedMs: json['m'] as int?,
      cloudOnly: json['c'] == true,
    );
  }
}

/// What one session said, kept so an unchanged session isn't read again.
class SessionRecord {
  const SessionRecord({
    required this.path,
    this.sizeBytes,
    this.modifiedMs,
    this.refs,
  });

  final String path;
  final int? sizeBytes;
  final int? modifiedMs;

  /// Its audio references; null when it couldn't be read.
  final List<SessionAudioRef>? refs;

  Map<String, Object?> toJson() => {
        'p': path,
        if (sizeBytes != null) 'z': sizeBytes,
        if (modifiedMs != null) 'm': modifiedMs,
        if (refs != null) 'r': [for (final r in refs!) r.toJson()],
      };

  static SessionRecord? fromJson(Object? json) {
    if (json is! Map || json['p'] is! String) return null;
    final refs = json['r'];
    return SessionRecord(
      path: json['p'] as String,
      sizeBytes: json['z'] as int?,
      modifiedMs: json['m'] as int?,
      refs: refs is List
          ? [
              for (final r in refs)
                if (SessionAudioRef.fromJson(r) case final ref?) ref,
            ]
          : null,
    );
  }
}

/// One audio file a session names: where it may be, most specific first.
class SessionAudioRef {
  const SessionAudioRef({required this.candidates, this.admSource = false});

  final List<String> candidates;

  /// A WaveLab montage's ADM master (the file it was imported from).
  final bool admSource;

  Map<String, Object?> toJson() => {'c': candidates, if (admSource) 'a': true};

  static SessionAudioRef? fromJson(Object? json) {
    if (json is! Map || json['c'] is! List) return null;
    final c = [for (final x in json['c'] as List) if (x is String) x];
    if (c.isEmpty) return null;
    return SessionAudioRef(candidates: c, admSource: json['a'] == true);
  }
}

/// Whether DAW Project Manager can read which audio files a session at
/// [sessionPath] refers to. Pro Tools sessions can't be read yet: their
/// contents are encoded (see PT Peek for those).
bool canReadSessionAudio(String sessionPath) {
  final ext = p.extension(sessionPath).toLowerCase();
  return ext == '.mon' || canReadSampleReferences(sessionPath);
}

/// What is known about a project's audio: its sessions, the files they
/// confirm, the other audio found in its folders, and when that was read.
/// This is what the audio index caches per project (device-local: paths name
/// places on this computer).
class AssociatedAudioReport {
  const AssociatedAudioReport({
    required this.sessionPaths,
    required this.folders,
    required this.confirmed,
    required this.discovered,
    required this.unreadableSessions,
    this.truncated = false,
    this.indexedAt,
    this.offlineFolders = const [],
    this.cloudOnlySessions = const [],
    this.sessions = const {},
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

  /// When this was read.
  final DateTime? indexedAt;

  /// Folders that weren't there when this was read (a drive not connected):
  /// what was known of them before is kept, not dropped.
  final List<String> offlineFolders;

  /// Sessions with a cloud provider, not on this computer: not read, so as
  /// not to download them.
  final List<String> cloudOnlySessions;

  /// What each session said, by path, for the next incremental read.
  final Map<String, SessionRecord> sessions;

  List<AssociatedAudioFile> get missing =>
      confirmed.where((f) => !f.exists).toList();

  /// Every file present, confirmed or discovered.
  Iterable<AssociatedAudioFile> get present =>
      [...confirmed, ...discovered].where((f) => f.exists);

  bool get hasAdm => present.any((f) => f.role == AudioRole.admMaster);

  Map<String, Object?> toJson() => {
        'v': 1,
        'sp': sessionPaths,
        'fo': folders,
        'cf': [for (final f in confirmed) f.toJson()],
        'df': [for (final f in discovered) f.toJson()],
        'us': unreadableSessions,
        if (truncated) 'tr': true,
        if (indexedAt != null) 'at': indexedAt!.toUtc().millisecondsSinceEpoch,
        if (offlineFolders.isNotEmpty) 'of': offlineFolders,
        if (cloudOnlySessions.isNotEmpty) 'cs': cloudOnlySessions,
        'ss': [for (final s in sessions.values) s.toJson()],
      };

  static AssociatedAudioReport? fromJson(Object? json) {
    if (json is! Map || json['v'] != 1) return null;
    List<String> strings(String k) =>
        [for (final x in (json[k] as List?) ?? const []) if (x is String) x];
    List<AssociatedAudioFile> files(String k) => [
          for (final x in (json[k] as List?) ?? const [])
            if (AssociatedAudioFile.fromJson(x) case final f?) f,
        ];
    final at = json['at'];
    return AssociatedAudioReport(
      sessionPaths: strings('sp'),
      folders: strings('fo'),
      confirmed: files('cf'),
      discovered: files('df'),
      unreadableSessions: strings('us'),
      truncated: json['tr'] == true,
      indexedAt: at is int
          ? DateTime.fromMillisecondsSinceEpoch(at, isUtc: true).toLocal()
          : null,
      offlineFolders: strings('of'),
      cloudOnlySessions: strings('cs'),
      sessions: {
        for (final x in (json['ss'] as List?) ?? const [])
          if (SessionRecord.fromJson(x) case final s?) s.path: s,
      },
    );
  }
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

/// The file system as the indexer sees it. Every call only asks about a
/// file (its size, date, cloud status) or reads the few bytes it needs; the
/// default is the real disk, and tests count what is read.
class AudioIndexIo {
  const AudioIndexIo();

  /// Size and modification time, or null when it isn't there.
  ({int size, int modifiedMs})? stat(String path) {
    try {
      final s = File(path).statSync();
      if (s.type != FileSystemEntityType.file) return null;
      return (size: s.size, modifiedMs: s.modified.millisecondsSinceEpoch);
    } catch (_) {
      return null;
    }
  }

  bool directoryExists(String path) {
    try {
      return Directory(path).existsSync();
    } catch (_) {
      return false;
    }
  }

  /// Entries directly in [path]: files and folders, by full path.
  List<(String, bool)> list(String path) {
    try {
      return [
        for (final e in Directory(path).listSync(followLinks: false))
          if (e is File || e is Directory) (e.path, e is Directory),
      ];
    } catch (_) {
      return const [];
    }
  }

  bool isCloudOnly(String path) {
    try {
      return isCloudOnlyFile(path);
    } catch (_) {
      return false;
    }
  }

  AudioFormatInfo? readFormat(String path) => readAudioFormatSync(path);

  /// The session's audio references, or null when they can't be read.
  List<SessionAudioRef>? readSession(String path) {
    final ext = p.extension(path).toLowerCase();
    try {
      if (ext == '.mon') {
        final parser = WaveLabMontageParser(File(path).readAsBytesSync());
        if (!parser.isMontage) return null;
        return [
          for (final r in parser.readAudioReferences())
            if (r.candidates.isNotEmpty)
              SessionAudioRef(
                candidates: r.candidates,
                admSource: r.role == WaveLabAudioRole.admSource,
              ),
        ];
      }
      if (canReadSampleReferences(path)) {
        return [
          for (final r in sampleReferencesFromBytes(ext, File(path).readAsBytesSync()))
            if (r.candidates.isNotEmpty) SessionAudioRef(candidates: r.candidates),
        ];
      }
    } catch (_) {}
    return null;
  }
}

/// Reads which audio files belong to a project, using what [previous] (the
/// cached result) already knows:
///
/// * a session whose size and date haven't changed isn't read again;
/// * an audio file whose size and date haven't changed keeps its header
///   details without being opened;
/// * a cloud-only file (its contents with a cloud provider) is never opened,
///   so nothing is downloaded — it is listed, marked as such;
/// * a folder that isn't there (a drive not connected) keeps what was known
///   of it before, marked offline, rather than losing it.
///
/// Nothing is written, moved or renamed. Synchronous: run it in a
/// background isolate ([readAssociatedAudio] does).
AssociatedAudioReport indexProjectAudio({
  required List<String> sessionPaths,
  required List<String> folders,
  AssociatedAudioReport? previous,
  AudioIndexIo io = const AudioIndexIo(),
  DateTime? now,
}) {
  final prevFiles = <String, AssociatedAudioFile>{
    for (final f in [...?previous?.confirmed, ...?previous?.discovered])
      _key(f.path): f,
  };
  final seen = <String>{};

  AssociatedAudioFile describe(
    String path, {
    required AudioOrigin origin,
    required String? projectFolder,
    String? sessionPath,
    bool admSource = false,
  }) {
    final st = io.stat(path);
    AudioRole role(AudioFormatInfo? format) => admSource
        ? AudioRole.admMaster
        : classifyAudioRole(path, projectFolder: projectFolder, format: format);
    if (st == null) {
      return AssociatedAudioFile(
        path: path,
        origin: origin,
        role: role(null),
        exists: false,
        sessionPath: sessionPath,
      );
    }
    final prev = prevFiles[_key(path)];
    AudioFormatInfo? format;
    var cloudOnly = false;
    if (prev != null &&
        prev.exists &&
        !prev.cloudOnly &&
        prev.sizeBytes == st.size &&
        prev.modifiedMs == st.modifiedMs) {
      // Unchanged since last time: never opened again.
      format = prev.format;
    } else if (io.isCloudOnly(path)) {
      cloudOnly = true;
    } else {
      format = io.readFormat(path);
    }
    return AssociatedAudioFile(
      path: path,
      origin: origin,
      role: role(format),
      exists: true,
      format: format,
      sessionPath: sessionPath,
      sizeBytes: st.size,
      modifiedMs: st.modifiedMs,
      cloudOnly: cloudOnly,
    );
  }

  // Sessions: confirmed references.
  final sessions = <String, SessionRecord>{};
  final confirmed = <AssociatedAudioFile>[];
  final unreadable = <String>[];
  final cloudSessions = <String>[];
  for (final session in sessionPaths) {
    final prev = previous?.sessions[session];
    final st = io.stat(session);
    List<SessionAudioRef>? refs;
    SessionRecord record;
    if (st == null) {
      // Not here (a drive not connected): what was known last time stands,
      // files and all — they aren't "missing", only out of reach.
      if (prev != null) {
        sessions[session] = prev;
        for (final f in previous?.confirmed ?? const <AssociatedAudioFile>[]) {
          if (f.sessionPath == session && seen.add(_key(f.path))) {
            confirmed.add(f);
          }
        }
      } else {
        unreadable.add(session);
      }
      continue;
    } else if (prev != null &&
        prev.refs != null &&
        prev.sizeBytes == st.size &&
        prev.modifiedMs == st.modifiedMs) {
      refs = prev.refs;
      record = prev;
    } else if (!canReadSessionAudio(session)) {
      record = SessionRecord(
          path: session, sizeBytes: st.size, modifiedMs: st.modifiedMs);
    } else if (io.isCloudOnly(session)) {
      cloudSessions.add(session);
      refs = prev?.refs;
      record = prev ?? SessionRecord(path: session);
    } else {
      refs = io.readSession(session);
      record = SessionRecord(
        path: session,
        sizeBytes: st.size,
        modifiedMs: st.modifiedMs,
        refs: refs,
      );
    }
    sessions[session] = record;
    if (refs == null) {
      if (!cloudSessions.contains(session)) unreadable.add(session);
      continue;
    }
    final base = p.dirname(session);
    for (final ref in refs) {
      final resolved = _resolve(ref.candidates, base, io);
      final path = resolved ?? _firstAbsolute(ref.candidates, base);
      if (!seen.add(_key(path))) continue;
      confirmed.add(describe(
        path,
        origin: AudioOrigin.confirmed,
        projectFolder: base,
        sessionPath: session,
        admSource: ref.admSource,
      ));
    }
  }

  // Folders: everything else.
  final discovered = <AssociatedAudioFile>[];
  final offline = <String>[];
  var truncated = false;
  for (final folder in folders) {
    if (!io.directoryExists(folder)) {
      offline.add(folder);
      for (final f in previous?.discovered ?? const <AssociatedAudioFile>[]) {
        if (p.isWithin(folder, f.path) && seen.add(_key(f.path))) {
          discovered.add(f);
        }
      }
      continue;
    }
    void walk(String dir, int depth) {
      if (truncated) return;
      final entries = io.list(dir)..sort((a, b) => a.$1.compareTo(b.$1));
      for (final (path, isDir) in entries) {
        final name = p.basename(path);
        if (name.startsWith('.')) continue; // hidden, and AppleDouble "._x"
        if (!isDir) {
          if (!kAssociatedAudioExtensions
              .contains(p.extension(name).toLowerCase())) {
            continue;
          }
          if (!seen.add(_key(path))) continue;
          if (discovered.length >= kMaxDiscoveredAudio) {
            truncated = true;
            return;
          }
          discovered.add(describe(path,
              origin: AudioOrigin.discovered, projectFolder: folder));
        } else if (depth < kAudioSearchDepth &&
            !_skippedFolders.contains(name.toLowerCase())) {
          walk(path, depth + 1);
        }
      }
    }

    walk(folder, 0);
  }
  discovered.sort(_byRoleThenName);

  return AssociatedAudioReport(
    sessionPaths: sessionPaths,
    folders: folders,
    confirmed: confirmed,
    discovered: discovered,
    unreadableSessions: unreadable,
    truncated: truncated,
    indexedAt: now ?? DateTime.now(),
    offlineFolders: offline,
    cloudOnlySessions: cloudSessions,
    sessions: sessions,
  );
}

/// [indexProjectAudio] in a background isolate, with nothing cached.
Future<AssociatedAudioReport> readAssociatedAudio({
  required List<String> sessionPaths,
  required List<String> folders,
  AssociatedAudioReport? previous,
}) =>
    Isolate.run(() => indexProjectAudio(
          sessionPaths: sessionPaths,
          folders: folders,
          previous: previous,
        ));

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
String? _resolve(List<String> candidates, String base, AudioIndexIo io) {
  for (final c in candidates) {
    final path = p.isAbsolute(c) ? p.normalize(c) : p.normalize(p.join(base, c));
    if (io.stat(path) != null) return path;
  }
  return null;
}

String _firstAbsolute(List<String> candidates, String base) {
  for (final c in candidates) {
    if (p.isAbsolute(c)) return p.normalize(c);
  }
  return p.normalize(p.join(base, candidates.first));
}
