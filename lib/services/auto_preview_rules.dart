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

/// Words that say nothing about which song a name is: what every session
/// and every bounce may be called ("Mix", "Master", "Final", "[48k Album]").
/// A session named only in such words has no reliable name to match.
const Set<String> kGenericNameWords = {
  'mix', 'mixes', 'mixdown', 'master', 'masters', 'mastered', 'mastering',
  'premaster', 'pre', 'post', 'final', 'session', 'sessions', 'project',
  'audio', 'untitled', 'song', 'track', 'tracks', 'bounce', 'bounced',
  'render', 'stereo', 'new', 'copy', 'dolby', 'atmos', 'immersive',
  'spatial', 'binaural', 'edit', 'version', 'album', 'ep', 'single',
  'demo', 'test', 'the', 'a', 'an', 'of', 'and', 'for', 'to', 'in', 'on',
  'wav', 'aif', 'aiff', 'mp3', 'mon', 'ptx', 'cpr', 'als', 'logicx',
  'recovered', 'bak', 'mst', 'mx', 'rmx', 'remix', 'v', 'website',
  '44k', '48k', '88k', '96k', '24bit', '16bit', '32bit', 'bit', 'khz',
};

bool _isSignificant(String w) => w.isNotEmpty && !kGenericNameWords.contains(w);

bool _hasNameWord(Iterable<String> words) =>
    words.any((w) => RegExp(r'[a-z\u00c0-\u024f]{3,}').hasMatch(w));

/// The words of a session's name that tell which song it is: its name
/// without [kGenericNameWords]. Numbers stay ("Mix21" and "Mix 25" are
/// different versions).
List<String> significantSessionWords(String sessionPath) => [
      for (final w
          in normalizeForMatch(p.basenameWithoutExtension(sessionPath))
              .split(' '))
        if (_isSignificant(w)) w,
    ];

/// Whether [audioPath] is reliably named after the session at
/// [sessionPath] (v3.0.6, strict). Either every significant word of the
/// session's name ([significantSessionWords]) is a word of the file's name;
/// or every significant word of its name without trailing version words
/// ([sessionNameCore]) is, and every version-like word in the file's name
/// (a number, "v2") is one the session's name has — so "Track 7.wav" is
/// never "Track 6", nor "Mix 2024_2" the session "Mix 2024_1". A session
/// named only in generic words ("Mix 2", "Untitled") never matches: there is
/// nothing to tell its song by. When in doubt, no.
bool previewNameReliablyMatches(String audioPath, String sessionPath) {
  final full = significantSessionWords(sessionPath);
  if (!_hasNameWord(full)) return false;
  final fileWords = normalizeForMatch(p.basenameWithoutExtension(audioPath))
      .split(' ')
      .where((w) => w.isNotEmpty)
      .toSet();
  if (full.every(fileWords.contains)) return true;

  final core = sessionNameCore(sessionPath).split(' ');
  final coreSignificant = [for (final w in core) if (_isSignificant(w)) w];
  if (!_hasNameWord(coreSignificant) ||
      !coreSignificant.every(fileWords.contains)) {
    return false;
  }
  final allWords = normalizeForMatch(p.basenameWithoutExtension(sessionPath))
      .split(' ')
      .where((w) => w.isNotEmpty)
      .toList();
  final sessionVersions = {
    for (final w in allWords)
      if (_versionWord.hasMatch(w)) w,
  };
  final fileVersions = {
    for (final w in fileWords)
      if (RegExp(r'^(\d+|v\d+)$').hasMatch(w)) w,
  };
  return fileVersions.every(sessionVersions.contains);
}

/// Names of single parts of a mix rather than the song: an instrument or
/// voice group, a stem, an object, a backing track, an instrumental or an
/// a cappella — whatever the role the folder suggests.
final RegExp _partWords = RegExp(
    r'(^| )(vocals?|vox|voices?|bvs?|backing|adlibs?|ad libs?|acapella|'
    r'a cappella|acappella|instrumentals?|inst|drums?|kick|snare|hats?|'
    r'percs?|percussion|bass|guitars?|gtrs?|keys|piano|synths?|pads?|'
    r'strings|horns|brass|fx|sfx|effects|dialog|dialogue|stems?|objects?|'
    r'obj|beds?|click|guide|reference track)( |$)');

/// A DAW's own backup, cache or working copies: never a song's preview,
/// even when named after it (WaveLab keeps rendered edits in
/// "<montage>.mon/edits").
const Set<String> _internalFolders = {
  'system.mon', 'backup.mon', 'session file backups', 'backup', 'backups',
  'auto-backups', 'autosave', 'auto save', 'cache', 'history',
};

/// Whether the file at [audioPath] is one part of a mix, never the song: a
/// stem or object (by its role), an instrument or voice group by its name,
/// one channel of a split ("Mix.L.wav", "Mix_1.LFE.wav") or a mono file
/// ([format] with one channel) — or a DAW's own backup or cache copy.
bool isPartOfMix(String audioPath, {AudioFormatInfo? format}) {
  if (p
      .split(p.dirname(audioPath))
      .any((folder) => _internalFolders.contains(folder.toLowerCase()))) {
    return true;
  }
  if (format != null && (format.channels ?? 2) == 1) return true;
  if (multiMonoPart(audioPath) != null) return true;
  if (classifyAudioRole(audioPath) == AudioRole.stem) return true;
  final name = normalizeForMatch(p.basenameWithoutExtension(audioPath));
  return _partWords.hasMatch(name);
}

/// Whether an automatic preview at [audioPath] may stand for the session at
/// [sessionPath] (v3.0.6, strict). It must never be a part of a mix
/// ([isPartOfMix]). Then either its name reliably matches the session
/// ([previewNameReliablyMatches]), or it was bounced into the session's own
/// mixdown folder ([inSessionBounceFolder]) in a folder that holds no other
/// session — the DAW's export for that one session. Anything else is
/// uncertain, and an uncertain preview is left empty.
bool autoPreviewFitsSession(
  String audioPath,
  String sessionPath, {
  required bool sharedFolder,
  bool inSessionBounceFolder = true,
  AudioFormatInfo? format,
}) {
  if (isPartOfMix(audioPath, format: format)) return false;
  if (previewNameReliablyMatches(audioPath, sessionPath)) return true;
  return inSessionBounceFolder && !sharedFolder;
}

/// Whether [audioPath] sits directly in one of [bounceFolderNames] right
/// under the session's folder ("Song/Bounces/Mix.wav" for "Song/Song.als"),
/// or in a bundle session's own Bounces ("Song.logicx/Bounces/…").
bool isInSessionBounceFolder(
  String audioPath,
  String sessionPath,
  Iterable<String> bounceFolderNames,
) {
  final names = {for (final n in bounceFolderNames) n.toLowerCase()};
  final parent = p.dirname(audioPath);
  if (!names.contains(p.basename(parent).toLowerCase())) return false;
  final holder = p.normalize(p.dirname(parent));
  return p.equals(holder, p.normalize(p.dirname(sessionPath))) ||
      p.equals(holder, p.normalize(sessionPath));
}

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
/// * present here, not cloud-only, exactly two channels by its header (a
///   compressed file without a readable header counts as stereo);
/// * a master, mix, bounce or render by its name or folder, and never a part
///   of a mix ([isPartOfMix]);
/// * reliably named after the session ([previewNameReliablyMatches]) —
///   wherever it was found. When in doubt, no preview.
/// * masters before mixes before bounces before renders, then the newest.
AssociatedAudioFile? bestStereoPreviewFrom(
  AssociatedAudioReport report, {
  required String sessionPath,
  required bool sharedFolder,
}) {
  bool stereo(AssociatedAudioFile f) {
    final format = f.format;
    if (format == null) {
      return _compressedPreviewExtensions
          .contains(p.extension(f.path).toLowerCase());
    }
    return !needsExternalPlayer(format) && (format.channels ?? 2) == 2;
  }

  final candidates = [
    for (final f in report.present)
      if (!f.cloudOnly &&
          _previewRoles.contains(f.role) &&
          stereo(f) &&
          !isPartOfMix(f.path, format: f.format) &&
          // From the audio found anywhere around a session, only a file
          // reliably named after it: a montage or a folder can hold a whole
          // album, and a confirmed reference is not the song it belongs to.
          previewNameReliablyMatches(f.path, sessionPath))
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
/// a session clip, a part of a mix ([isPartOfMix]), or not reliably this
/// session's ([autoPreviewFitsSession]).
String? autoPreviewProblem(
  String audioPath,
  String sessionPath, {
  required bool sharedFolder,
  bool inSessionBounceFolder = true,
  AudioFormatInfo? format,
}) {
  final rejection = autoPreviewRejection(audioPath,
      projectFolder: p.dirname(sessionPath), format: format);
  if (rejection != null) return rejection.name;
  if (isPartOfMix(audioPath, format: format)) return 'partOfMix';
  if (!autoPreviewFitsSession(audioPath, sessionPath,
      sharedFolder: sharedFolder,
      inSessionBounceFolder: inSessionBounceFolder,
      format: format)) {
    return 'notReliablyThisSession';
  }
  return null;
}
