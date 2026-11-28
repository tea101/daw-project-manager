import 'package:path/path.dart' as p;

import '../../utils/audio_format_info.dart';

/// What an audio file found with a project is to it, as far as can be told.
enum AudioRole {
  /// A Dolby Atmos or other ADM BWF master — told by its header, never its
  /// name.
  admMaster,

  /// A stem: one part of a mix (by its name or a "Stems" folder).
  stem,

  /// Audio the session plays from its own media folder: a recorded or
  /// imported clip (Pro Tools' "Audio Files", WaveLab's "audio", Cubase's
  /// "Audio", Ableton's "Samples").
  sessionClip,

  /// A master, by its name.
  master,

  /// A mix, by its name.
  mix,

  /// A file in a bounce or mixdown folder.
  bounce,

  /// A file in a render folder.
  render,

  /// Nothing says.
  other,
}

/// Media folders DAWs keep a session's own clips in. Lowercase.
const Set<String> kSessionMediaFolders = {
  'audio files', // Pro Tools
  'audio', // WaveLab, Cubase, Nuendo, Studio One ("Media" too)
  'media',
  'samples', // Ableton Live
  'recorded',
  'processed',
  'imported',
  'fade files',
  'clip gain',
  'sampler audio files',
  'ara data',
};

const Set<String> _bounceFolders = {
  'bounced files', 'bounce', 'bounces', 'mixdown', 'mixdowns', 'export',
  'exports', 'exported files',
};

const Set<String> _renderFolders = {'render', 'renders', 'rendered'};

final RegExp _stemWord = RegExp(r'(^|[^a-z])stems?([^a-z]|$)');
final RegExp _masterWord = RegExp(r'(^|[^a-z])master(ed|ing)?([^a-z]|$)');
final RegExp _mixWord = RegExp(r'(^|[^a-z])(mix|mixdown)([^a-z]|$)');

/// The folders between [projectFolder] and [path], lowercase. When the file
/// is not under the project folder, its own nearest folder only.
List<String> _foldersBetween(String path, String? projectFolder) {
  final dir = p.dirname(path);
  if (projectFolder != null && p.isWithin(projectFolder, path)) {
    return p
        .split(p.relative(dir, from: projectFolder))
        .where((s) => s != '.')
        .map((s) => s.toLowerCase())
        .toList();
  }
  return [p.basename(dir).toLowerCase()];
}

/// The role of the audio file at [path] for the project in [projectFolder].
///
/// An ADM master is recognised by its [format] only. Otherwise the file's
/// own name is read for "stem", then the folders it is in for a session's
/// media, then its name for "master" and "mix", then the folders for
/// bounces and renders. Names never decide that something is an ADM master
/// or how many channels it has.
AudioRole classifyAudioRole(
  String path, {
  String? projectFolder,
  AudioFormatInfo? format,
}) {
  if (format != null && format.isAdm) return AudioRole.admMaster;
  final name = p.basenameWithoutExtension(path).toLowerCase();
  final folders = _foldersBetween(path, projectFolder);

  if (_stemWord.hasMatch(name) || folders.any((f) => _stemWord.hasMatch(f))) {
    return AudioRole.stem;
  }
  if (folders.any(kSessionMediaFolders.contains)) return AudioRole.sessionClip;
  if (_masterWord.hasMatch(name)) return AudioRole.master;
  if (_mixWord.hasMatch(name)) return AudioRole.mix;
  if (folders.any(_bounceFolders.contains)) return AudioRole.bounce;
  if (folders.any(_renderFolders.contains)) return AudioRole.render;
  return AudioRole.other;
}

/// Why the file at [path] must not be picked as a preview automatically, or
/// null when it may be. Stems, a session's own clips and ADM masters are
/// never picked, nor anything with more than two channels: playing it
/// through the preview player would be a downmix nobody asked for.
///
/// [format] is the file's header, read by the caller when it can be (a
/// format the header reader doesn't know, like MP3, leaves it null and only
/// the name rules apply).
AutoPreviewRejection? autoPreviewRejection(
  String path, {
  String? projectFolder,
  AudioFormatInfo? format,
}) {
  if (format != null && format.isAdm) return AutoPreviewRejection.admMaster;
  if (format != null && format.isMultichannel) {
    return AutoPreviewRejection.multichannel;
  }
  final role = classifyAudioRole(path, projectFolder: projectFolder);
  if (role == AudioRole.stem) return AutoPreviewRejection.stem;
  if (role == AudioRole.sessionClip) return AutoPreviewRejection.sessionClip;
  return null;
}

enum AutoPreviewRejection { admMaster, multichannel, stem, sessionClip }

/// Pro Tools' (and others') multi-mono channel suffixes: "Mix.L.wav",
/// "Mix.Ltf.wav". Lowercase, without the dot.
const List<String> kMultiMonoSuffixes = [
  'l', 'r', 'c', 'lfe', 'ls', 'rs', 'lss', 'rss', 'lsr', 'rsr', 'lrs', 'rrs',
  'ltf', 'rtf', 'ltm', 'rtm', 'ltr', 'rtr', 'lts', 'rts', 'cs', 'lc', 'rc',
];

/// For "Mix.Ltf.wav", the group it belongs to ("<folder>/Mix") and its
/// channel ("Ltf", as written). Null for a file that isn't one channel of a
/// multi-mono set.
({String group, String channel})? multiMonoPart(String path) {
  final base = p.basenameWithoutExtension(path);
  final dot = base.lastIndexOf('.');
  if (dot <= 0 || dot == base.length - 1) return null;
  final suffix = base.substring(dot + 1);
  if (!kMultiMonoSuffixes.contains(suffix.toLowerCase())) return null;
  return (
    group: p.join(p.dirname(path), base.substring(0, dot)),
    channel: suffix,
  );
}
