import 'package:path/path.dart' as p;

import '../models/music_project.dart';

/// Audio file extensions a library row can be (a standalone audio file),
/// with a leading dot, lowercase.
const Set<String> kStandaloneAudioExtensions = {
  '.wav', '.wave', '.bwf', '.rf64', '.w64',
  '.aif', '.aiff', '.aifc',
  '.flac', '.mp3', '.m4a', '.aac', '.ogg',
};

/// Short labels for extensions whose plain form isn't the one people use
/// ("aiff" is aif, "wave" and "bwf" are wav).
///
/// Labels are lowercase, as file extensions are written (ptx, mon, wav):
/// they are display text only, and no file is ever renamed.
const Map<String, String> _labelOverrides = {
  '.wave': 'wav',
  '.bwf': 'wav',
  '.aiff': 'aif',
  '.aifc': 'aif',
  '.mmpz': 'mmp',
  '.tracktionedit': 'tracktion',
  '.bwproject': 'bwp',
  '.maschine2': 'maschine',
};

/// The label a version stack shows: it is a group of versions the app
/// keeps, not a folder on disk, even though its path names one.
const String kStackFileTypeLabel = 'stack';

/// The label for a row whose path is a plain folder.
const String kFolderFileTypeLabel = 'folder';

/// The File Type column's label for [project]: the actual file's type, from
/// its path — never from the project's name.
///
/// * A version stack is [kStackFileTypeLabel]: it owns no file, and its path
///   is only where its versions sit.
/// * A bundle saved as a folder (Logic's `.logicx`) is its own type.
/// * A path with no extension is a folder ([kFolderFileTypeLabel]).
String projectFileTypeLabel(MusicProject project) {
  if (project.isVirtual) return kStackFileTypeLabel;
  return fileTypeLabelForPath(project.filePath);
}

/// [projectFileTypeLabel] for a path alone.
String fileTypeLabelForPath(String path) {
  final ext = p.extension(path).toLowerCase();
  if (ext.isEmpty || ext == '.') return kFolderFileTypeLabel;
  return _labelOverrides[ext] ?? ext.substring(1);
}

/// Whether [project] is a standalone audio file in the library rather than a
/// DAW session: its own file is audio. Stacks never are.
bool isStandaloneAudioProject(MusicProject project) =>
    !project.isVirtual &&
    kStandaloneAudioExtensions
        .contains(p.extension(project.filePath).toLowerCase());
