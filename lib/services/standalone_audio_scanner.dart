import 'dart:io';

import 'package:path/path.dart' as p;

import '../utils/project_file_type.dart';
import 'associated_audio/audio_roles.dart';
import 'scanner_service.dart';

/// Folders never searched for standalone audio: DAWs' backups and caches.
const Set<String> _skipped = {
  'session file backups', 'backup', 'backups', 'auto-backups', 'autosave',
  'auto save', 'history', 'system.mon', 'backup.mon', 'cache', '__macosx',
};

/// Audio files under [rootPath] that no DAW session owns: in folders where
/// no session (or bundle) sits, nor in any folder above them up to the
/// root (v3.0.6, behind the "standalone audio files" setting).
///
/// A folder holding a session is the session's: its audio is shown on that
/// project's page instead (confirmed or found in its folder), never as rows
/// of its own. Only names are read — never a file's contents.
Stream<File> findStandaloneAudio(
  String rootPath, {
  List<String> ignoredPaths = const [],
}) async* {
  final ignored = [for (final x in ignoredPaths) p.normalize(x)];
  bool isIgnored(String path) {
    final n = p.normalize(path);
    return ignored.any((base) => n == base || p.isWithin(base, n));
  }

  final stack = <Directory>[Directory(rootPath)];
  while (stack.isNotEmpty) {
    final dir = stack.removeLast();
    if (isIgnored(dir.path)) continue;
    List<FileSystemEntity> entries;
    try {
      entries = await dir.list(followLinks: false).toList();
    } catch (_) {
      continue;
    }
    final ownsSession = entries.any((e) {
      final name = p.basename(e.path);
      if (name.startsWith('._')) return false;
      if (e is Directory) return ScannerService.isBundlePath(e.path);
      return e is File &&
          ScannerService.supportedExtensions
              .contains(p.extension(e.path).toLowerCase());
    });
    if (ownsSession) continue;

    for (final e in entries) {
      final name = p.basename(e.path);
      if (name.startsWith('.')) continue;
      if (isIgnored(e.path)) continue;
      if (e is File) {
        if (kStandaloneAudioExtensions
            .contains(p.extension(name).toLowerCase())) {
          yield e;
        }
      } else if (e is Directory) {
        final lower = name.toLowerCase();
        if (_skipped.contains(lower) || kSessionMediaFolders.contains(lower)) {
          continue;
        }
        stack.add(e);
      }
    }
  }
}
