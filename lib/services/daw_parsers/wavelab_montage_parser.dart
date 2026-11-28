import 'dart:convert';
import 'dart:typed_data';

/// What a WaveLab montage says about one audio file it uses.
enum WaveLabAudioRole {
  /// The source of a clip on the montage's tracks.
  clipSource,

  /// The ADM BWF master the montage was made from (an ADM import).
  admSource,
}

/// One audio file a WaveLab audio montage references.
class WaveLabAudioRef {
  const WaveLabAudioRef({
    required this.role,
    this.absolutePath,
    this.relativePath,
  });

  final WaveLabAudioRole role;

  /// Where the file was when the montage was saved. Often stale after a
  /// drive is renamed — WaveLab keeps it alongside [relativePath].
  final String? absolutePath;

  /// The same file relative to the montage's folder, which still resolves
  /// after a whole project folder has moved.
  final String? relativePath;

  /// Paths to try, relative first: it survives a renamed drive.
  List<String> get candidates => [
        if (relativePath != null && relativePath!.isNotEmpty) relativePath!,
        if (absolutePath != null && absolutePath!.isNotEmpty) absolutePath!,
      ];

  String get fileName {
    final path = (absolutePath?.isNotEmpty ?? false) ? absolutePath! : relativePath!;
    final parts = path.split(RegExp(r'[\\/]'));
    return parts.last;
  }

  @override
  bool operator ==(Object other) =>
      other is WaveLabAudioRef &&
      other.role == role &&
      other.absolutePath == absolutePath &&
      other.relativePath == relativePath;

  @override
  int get hashCode => Object.hash(role, absolutePath, relativePath);

  @override
  String toString() => 'WaveLabAudioRef(${role.name}, $absolutePath | $relativePath)';
}

/// Reads the audio files a WaveLab audio montage (`.mon`) references.
///
/// WaveLab 13's montage is a binary file that opens with `LE3\0` and the
/// text `WaveLabAudioMontage<version>`. File references are UTF-16LE text,
/// each after a four-byte record tag:
///
/// * `P8\0\0` — a clip's source, written as `<absolute>|<relative>`, the
///   relative part from the montage's folder ("audio/bed_1_3.wav").
/// * `admM` — the ADM master the montage was imported from: its absolute
///   path, sometimes followed by a second `admM` record with the relative one.
///
/// The format is not published: these were read from real WaveLab 13.0
/// montages (stereo, and Dolby Atmos ADM imports of 1–94 clips). Anything
/// that doesn't look like an audio file path is ignored rather than guessed,
/// so a montage this reader doesn't understand gives no references, never
/// wrong ones.
class WaveLabMontageParser {
  WaveLabMontageParser(this.bytes);

  final Uint8List bytes;

  static const _magic = [0x4C, 0x45, 0x33, 0x00]; // "LE3\0"

  /// Whether the bytes start like a WaveLab montage.
  bool get isMontage {
    if (bytes.length < 64) return false;
    for (var i = 0; i < 4; i++) {
      if (bytes[i] != _magic[i]) return false;
    }
    return _ascii(16, 64).contains('WaveLabAudioMontage');
  }

  /// "13.0", from the header's `WaveLabAudioMontage13.0`.
  String? get version {
    final m = RegExp(r'WaveLabAudioMontage([0-9.]+)').firstMatch(_ascii(16, 64));
    return m?.group(1);
  }

  static final _audio = RegExp(
    r'\.(wav|wave|bwf|rf64|w64|aif|aiff|aifc|flac|mp3|m4a|aac|ogg|caf)$',
    caseSensitive: false,
  );

  /// The audio files the montage references, each once, in file order.
  List<WaveLabAudioRef> readAudioReferences() {
    if (!isMontage) return const [];
    final out = <WaveLabAudioRef>[];
    final seen = <WaveLabAudioRef>{};
    WaveLabAudioRef? pendingAdm;

    void add(WaveLabAudioRef ref) {
      if (seen.add(ref)) out.add(ref);
    }

    for (final (tag, text) in _utf16Strings()) {
      if (tag == 'P8\x00\x00') {
        final bar = text.indexOf('|');
        final abs = bar < 0 ? text : text.substring(0, bar);
        final rel = bar < 0 ? null : text.substring(bar + 1);
        if (!_audio.hasMatch(abs) && !(rel != null && _audio.hasMatch(rel))) {
          continue;
        }
        add(WaveLabAudioRef(
          role: WaveLabAudioRole.clipSource,
          absolutePath: _isAbsolute(abs) ? abs : null,
          relativePath: rel ?? (_isAbsolute(abs) ? null : abs),
        ));
      } else if (tag == 'admM') {
        if (!_audio.hasMatch(text)) continue;
        if (_isAbsolute(text)) {
          if (pendingAdm != null) add(pendingAdm);
          pendingAdm = WaveLabAudioRef(
            role: WaveLabAudioRole.admSource,
            absolutePath: text,
          );
        } else if (pendingAdm != null) {
          // The second admM record: the same file, relative.
          add(WaveLabAudioRef(
            role: WaveLabAudioRole.admSource,
            absolutePath: pendingAdm.absolutePath,
            relativePath: text,
          ));
          pendingAdm = null;
        } else {
          add(WaveLabAudioRef(role: WaveLabAudioRole.admSource, relativePath: text));
        }
      }
    }
    if (pendingAdm != null) add(pendingAdm);
    return out;
  }

  static bool _isAbsolute(String path) =>
      path.startsWith('/') ||
      path.startsWith(r'\\') ||
      RegExp(r'^[A-Za-z]:[\\/]').hasMatch(path);

  String _ascii(int from, int to) {
    final end = to < bytes.length ? to : bytes.length;
    return latin1.decode(bytes.sublist(from, end), allowInvalid: true);
  }

  /// Every run of at least four printable UTF-16LE characters, with the
  /// four bytes that sit eight bytes before it (the record's tag).
  Iterable<(String, String)> _utf16Strings() sync* {
    var i = 0;
    final n = bytes.length;
    while (i + 1 < n) {
      final start = i;
      final units = <int>[];
      while (i + 1 < n) {
        final lo = bytes[i], hi = bytes[i + 1];
        final unit = lo | (hi << 8);
        // Printable text, not control characters. A unit whose low byte is
        // zero is ASCII read one byte out of step ("/" as 0x2F00), which
        // would swallow the real string that starts a byte later.
        if (unit < 0x20 ||
            (unit >= 0x7F && unit < 0xA0) ||
            unit == 0xFFFF ||
            (unit & 0xFF) == 0) {
          break;
        }
        units.add(unit);
        i += 2;
      }
      if (units.length >= 4 && start >= 8) {
        final tag = latin1.decode(bytes.sublist(start - 8, start - 4));
        yield (tag, String.fromCharCodes(units));
      }
      i = units.isEmpty ? start + 1 : i;
    }
  }
}
