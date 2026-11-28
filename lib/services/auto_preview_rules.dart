import 'package:path/path.dart' as p;

import '../utils/audio_format_info.dart';
import 'associated_audio/associated_audio_service.dart';
import 'associated_audio/audio_roles.dart';
import 'external_player.dart';

/// Rules for **automatic** preview songs (v3.0.6). A preview the user chose
/// (`previewSongPath`) is never judged by them, changed or cleared.
///
/// Found on a real library: one bounce folder shared by fourteen Pro Tools
/// sessions gave every one of them the same newest file ("Extra Groove.mp3"),
/// and nine sessions' automatic previews were 10-channel Atmos bounces the
/// stereo player can't play.

/// Lowercase words of [name], with everything but letters and digits as a
/// separator: "Jaju - MotorWayToO_Mix 2" -> "jaju motorwaytoo mix 2".
String normalizeForMatch(String name) => name
    .toLowerCase()
    .replaceAll(RegExp(r'[^a-z0-9À-ɏ]+'), ' ')
    .trim();

/// Trailing words that only tell versions of one song apart: numbers,
/// "v2", "recovered", "copy", "final".
final RegExp _versionWord =
    RegExp(r'^(\d+|v\d+|recovered|copy|final|bak)$');

/// [normalizeForMatch] of a session's name without its trailing version
/// words: "Song Dolby Atmos 2024_1.recovered" -> "song dolby atmos".
/// Never empties a name: a name made only of such words is kept whole.
String sessionNameCore(String sessionPath) {
  final words = normalizeForMatch(p.basenameWithoutExtension(sessionPath))
      .split(' ')
      .where((w) => w.isNotEmpty)
      .toList();
  var end = words.length;
  while (end > 1 && _versionWord.hasMatch(words[end - 1])) {
    end--;
  }
  return words.sublist(0, end).join(' ');
}

/// Whether the audio file at [audioPath] is named after the session at
/// [sessionPath]: one name contains the other (whole words), with or
/// without the session's trailing version words. "Ghetto In the Sky Dolby
/// Atmos Asward 2_1.wav" is named after "Dolby Atmos Asward 2.ptx";
/// "Extra Groove.mp3" is not named after "Miles - Afrobeat.Mix-Track 6.ptx".
bool previewNameMatchesSession(String audioPath, String sessionPath) {
  final file = ' ${normalizeForMatch(p.basenameWithoutExtension(audioPath))} ';
  for (final name in {
    normalizeForMatch(p.basenameWithoutExtension(sessionPath)),
    sessionNameCore(sessionPath),
  }) {
    if (name.length < 3) continue;
    if (file.contains(' $name ')) return true;
    final fileName = file.trim();
    if (fileName.length >= 3 && ' $name '.contains(' $fileName ')) {
      return true;
    }
  }
  return false;
}

/// Whether an automatic preview at [audioPath] may stand for the session at
/// [sessionPath]. In a folder shared by several sessions ([sharedFolder])
/// the file must be named after this session — otherwise every session
/// there gets the same newest file. In a folder of its own, any file will
/// do, as before.
bool autoPreviewFitsSession(
  String audioPath,
  String sessionPath, {
  required bool sharedFolder,
}) =>
    !sharedFolder || previewNameMatchesSession(audioPath, sessionPath);

/// Roles an automatic preview may have when chosen from the audio index:
/// what a finished stereo song is called or where one is kept. Never a stem,
/// a session's own clip or an ADM master; "other" (no telling name) neither.
const Set<AudioRole> _previewRoles = {
  AudioRole.master,
  AudioRole.mix,
  AudioRole.bounce,
  AudioRole.render,
};

/// Extensions an automatic preview may have when its header can't be read
/// here (compressed formats): they are stereo or mono in practice, and the
/// player still checks before playing.
const Set<String> _compressedPreviewExtensions = {'.mp3', '.m4a', '.aac'};

/// The best automatic stereo preview among the audio the index found for a
/// project, or null. Only for a project with no preview at all — the caller
/// checks that.
///
/// * present here, not cloud-only, stereo or mono by its header (a
///   compressed file without a readable header counts as stereo);
/// * a master, mix, bounce or render by its name or folder;
/// * named after the session when the folder is shared by several sessions,
///   and always when it was found in a folder the user added (such folders
///   often hold a whole album);
/// * masters before mixes before bounces before renders, then the newest.
AssociatedAudioFile? bestStereoPreviewFrom(
  AssociatedAudioReport report, {
  required String sessionPath,
  required bool sharedFolder,
}) {
  bool stereoOrMono(AssociatedAudioFile f) {
    final format = f.format;
    if (format == null) {
      return _compressedPreviewExtensions
          .contains(p.extension(f.path).toLowerCase());
    }
    return !needsExternalPlayer(format);
  }

  final candidates = [
    for (final f in report.present)
      if (!f.cloudOnly &&
          _previewRoles.contains(f.role) &&
          stereoOrMono(f) &&
          (f.origin == AudioOrigin.addedFolder
              ? previewNameMatchesSession(f.path, sessionPath)
              : autoPreviewFitsSession(f.path, sessionPath,
                  sharedFolder: sharedFolder)))
        f,
  ];
  if (candidates.isEmpty) return null;
  int rank(AudioRole r) => switch (r) {
        AudioRole.master => 0,
        AudioRole.mix => 1,
        AudioRole.bounce => 2,
        _ => 3,
      };
  candidates.sort((a, b) {
    final r = rank(a.role).compareTo(rank(b.role));
    if (r != 0) return r;
    return (b.modifiedMs ?? 0).compareTo(a.modifiedMs ?? 0);
  });
  return candidates.first;
}

/// Why an existing automatic preview should go, or null to keep it: it is
/// multichannel or ADM ([format], when its header could be read), a stem or
/// a session clip, or — in a folder shared by several sessions — not named
/// after this session.
String? autoPreviewProblem(
  String audioPath,
  String sessionPath, {
  required bool sharedFolder,
  AudioFormatInfo? format,
}) {
  final rejection = autoPreviewRejection(audioPath,
      projectFolder: p.dirname(sessionPath), format: format);
  if (rejection != null) return rejection.name;
  if (!autoPreviewFitsSession(audioPath, sessionPath,
      sharedFolder: sharedFolder)) {
    return 'sharedFolderMismatch';
  }
  return null;
}
