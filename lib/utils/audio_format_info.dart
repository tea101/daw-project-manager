import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

/// The container an audio file's header names.
enum AudioContainer { wav, rf64, bw64, aiff, aifc, flac, other }

/// What an audio file is, read from its header and chunk list alone — never
/// from its name, and never by reading the audio itself.
///
/// An ADM master is told by its `axml` and `chna` chunks, which Dolby's tools
/// write *after* gigabytes of audio: the reader jumps from chunk header to
/// chunk header (through `ds64` for RF64/BW64 files over 4 GB), so finding
/// them costs a few small reads however large the file is.
class AudioFormatInfo {
  const AudioFormatInfo({
    required this.container,
    this.channels,
    this.sampleRate,
    this.bitsPerSample,
    this.duration,
    this.channelMask,
    this.hasAxml = false,
    this.hasChna = false,
    this.hasDolbyMetadata = false,
    this.hasBext = false,
  });

  final AudioContainer container;
  final int? channels;
  final int? sampleRate;
  final int? bitsPerSample;
  final Duration? duration;

  /// `dwChannelMask` of a WAVE_FORMAT_EXTENSIBLE header: which speakers the
  /// channels feed. Null when the file doesn't say (a plain 16-byte `fmt `),
  /// and then nothing about speakers is assumed.
  final int? channelMask;

  /// ADM XML (`axml`), as in an ADM BWF master.
  final bool hasAxml;

  /// ADM channel allocation (`chna`).
  final bool hasChna;

  /// Dolby's own metadata chunk (`dbmd`), written by Dolby Atmos tools.
  final bool hasDolbyMetadata;

  /// Broadcast Wave description (`bext`).
  final bool hasBext;

  /// An ADM BWF file: audio described by ADM metadata, which needs a
  /// renderer to be heard as intended — beds and objects, not speakers.
  bool get isAdm => hasAxml || hasChna;

  /// An ADM BWF carrying Dolby's metadata: a Dolby Atmos master.
  bool get isDolbyAtmosAdm => isAdm && hasDolbyMetadata;

  /// More than two channels: playing it through a stereo player would be a
  /// downmix.
  bool get isMultichannel => (channels ?? 0) > 2;

  /// The speaker layout, only where the file states it (its channel mask).
  /// Null otherwise — a channel count is shown instead of a guess.
  String? get speakerLayout {
    final mask = channelMask;
    final n = channels;
    if (mask == null || mask == 0 || n == null) return null;
    if (_bitCount(mask) != n) return null;
    return kSpeakerLayouts[mask];
  }

  @override
  String toString() =>
      'AudioFormatInfo(${container.name}, ch=$channels, $sampleRate Hz, '
      '${bitsPerSample}bit, mask=$channelMask, adm=$isAdm, dbmd=$hasDolbyMetadata)';
}

/// Speaker layouts by WAVE_FORMAT_EXTENSIBLE channel mask.
///
/// Speaker bits: FL 0x1, FR 0x2, FC 0x4, LFE 0x8, BL 0x10, BR 0x20,
/// FLC 0x40, FRC 0x80, BC 0x100, SL 0x200, SR 0x400, TC 0x800,
/// TFL 0x1000, TFC 0x2000, TFR 0x4000, TBL 0x8000, TBC 0x10000, TBR 0x20000.
const Map<int, String> kSpeakerLayouts = {
  0x4: 'Mono',
  0x3: 'Stereo',
  0x7: 'LCR',
  0x33: 'Quad',
  0x603: 'Quad',
  0x37: '5.0',
  0x607: '5.0',
  0x3F: '5.1',
  0x60F: '5.1',
  0x63F: '7.1',
  0xFF: '7.1 (wide)',
  0x63F | 0x1000 | 0x4000: '7.1.2',
  0x60F | 0x1000 | 0x4000 | 0x8000 | 0x20000: '5.1.4',
  0x63F | 0x1000 | 0x4000 | 0x8000 | 0x20000: '7.1.4',
};

int _bitCount(int v) {
  var n = 0;
  while (v != 0) {
    n += v & 1;
    v >>= 1;
  }
  return n;
}

/// A short description for a list: "7.1.4", "2 ch", "ADM BWF · 103 ch".
/// A speaker layout only where the file states one.
String audioFormatSummary(AudioFormatInfo info) {
  final n = info.channels;
  final count = n == null ? null : '$n ch';
  if (info.isAdm) {
    final kind = info.isDolbyAtmosAdm ? 'Dolby Atmos ADM BWF' : 'ADM BWF';
    return count == null ? kind : '$kind · $count';
  }
  return info.speakerLayout ?? count ?? '';
}

/// Reads what the audio file at [path] is from its header, off the UI
/// thread. Null for formats without a readable header here (MP3, AAC, OGG),
/// a damaged header or an unreadable file; never throws.
Future<AudioFormatInfo?> readAudioFormat(String path) async {
  try {
    return await Isolate.run(() => readAudioFormatSync(path));
  } catch (_) {
    return null;
  }
}

/// [readAudioFormat] on the calling thread, for code that must decide at
/// once (choosing an automatic preview). Reads a few small pieces of the
/// file, never its audio.
AudioFormatInfo? readAudioFormatSync(String path) {
  RandomAccessFile? file;
  try {
    file = File(path).openSync();
    return readAudioFormatFrom(file);
  } catch (_) {
    return null;
  } finally {
    try {
      file?.closeSync();
    } catch (_) {}
  }
}

/// The parser behind [readAudioFormatSync], on an open file.
AudioFormatInfo? readAudioFormatFrom(RandomAccessFile file) {
  final length = file.lengthSync();
  final head = _at(file, 0, 12);
  if (head.length < 12) return null;
  final id = String.fromCharCodes(head.sublist(0, 4));
  final form = String.fromCharCodes(head.sublist(8, 12));
  if (form == 'WAVE' && (id == 'RIFF' || id == 'RF64' || id == 'BW64')) {
    return _wave(file, length, switch (id) {
      'RF64' => AudioContainer.rf64,
      'BW64' => AudioContainer.bw64,
      _ => AudioContainer.wav,
    });
  }
  if (id == 'FORM' && (form == 'AIFF' || form == 'AIFC')) {
    return _aiff(file, length, form == 'AIFC');
  }
  if (id.startsWith('fLaC')) return _flac(file);
  return null;
}

Uint8List _at(RandomAccessFile file, int position, int count) {
  file.setPositionSync(position);
  return file.readSync(count);
}

AudioFormatInfo _wave(RandomAccessFile file, int length, AudioContainer container) {
  int? channels, rate, bits, byteRate, mask, dataSize, ds64Data;
  var axml = false, chna = false, dbmd = false, bext = false;
  var pos = 12;
  for (var guard = 0; guard < 1024 && pos + 8 <= length; guard++) {
    final header = _at(file, pos, 8);
    if (header.length < 8) break;
    final id = String.fromCharCodes(header.sublist(0, 4));
    var size = ByteData.sublistView(header).getUint32(4, Endian.little);
    switch (id) {
      case 'ds64':
        final d = _at(file, pos + 8, 24);
        if (d.length >= 24) {
          ds64Data = ByteData.sublistView(d).getUint64(8, Endian.little);
        }
      case 'fmt ':
        final d = _at(file, pos + 8, size < 40 ? size : 40);
        if (d.length >= 16) {
          final f = ByteData.sublistView(d);
          channels = f.getUint16(2, Endian.little);
          rate = f.getUint32(4, Endian.little);
          byteRate = f.getUint32(8, Endian.little);
          bits = f.getUint16(14, Endian.little);
          if (f.getUint16(0, Endian.little) == 0xFFFE && d.length >= 24) {
            mask = f.getUint32(20, Endian.little);
          }
        }
      case 'data':
        // RF64/BW64 keep the real size in ds64 and 0xFFFFFFFF here.
        if (size == 0xFFFFFFFF && ds64Data != null) size = ds64Data;
        final available = length - pos - 8;
        if (size == 0 || size > available) size = available;
        dataSize = size;
      case 'axml':
        axml = true;
      case 'chna':
        chna = true;
      case 'dbmd':
        dbmd = true;
      case 'bext':
        bext = true;
    }
    pos += 8 + size + (size.isOdd ? 1 : 0);
  }
  Duration? duration;
  if (dataSize != null && byteRate != null && byteRate > 0) {
    duration = Duration(microseconds: (dataSize * 1000000 / byteRate).round());
  }
  return AudioFormatInfo(
    container: container,
    channels: channels,
    sampleRate: rate,
    bitsPerSample: bits,
    duration: duration,
    channelMask: mask,
    hasAxml: axml,
    hasChna: chna,
    hasDolbyMetadata: dbmd,
    hasBext: bext,
  );
}

AudioFormatInfo? _aiff(RandomAccessFile file, int length, bool aifc) {
  var pos = 12;
  for (var guard = 0; guard < 512 && pos + 8 <= length; guard++) {
    final header = _at(file, pos, 8);
    if (header.length < 8) return null;
    final id = String.fromCharCodes(header.sublist(0, 4));
    final size = ByteData.sublistView(header).getUint32(4, Endian.big);
    if (id == 'COMM' && size >= 18) {
      final d = _at(file, pos + 8, 18);
      if (d.length < 18) return null;
      final c = ByteData.sublistView(d);
      final frames = c.getUint32(2);
      final rate = _extended(c, 8);
      return AudioFormatInfo(
        container: aifc ? AudioContainer.aifc : AudioContainer.aiff,
        channels: c.getUint16(0),
        sampleRate: rate?.round(),
        bitsPerSample: c.getUint16(6),
        duration: rate == null || rate <= 0
            ? null
            : Duration(microseconds: (frames * 1000000 / rate).round()),
      );
    }
    pos += 8 + size + (size.isOdd ? 1 : 0);
  }
  return null;
}

double? _extended(ByteData data, int offset) {
  final exponent = data.getUint16(offset) & 0x7FFF;
  final mantissa =
      data.getUint32(offset + 2) * 4294967296.0 + data.getUint32(offset + 6);
  if (exponent == 0 && mantissa == 0) return 0;
  if (exponent == 0x7FFF) return null;
  var e = exponent - 16383 - 63;
  var v = mantissa;
  for (; e > 0; e--) {
    v *= 2;
  }
  for (; e < 0; e++) {
    v /= 2;
  }
  return v;
}

AudioFormatInfo? _flac(RandomAccessFile file) {
  // "fLaC", then the first metadata block, always STREAMINFO.
  final block = _at(file, 4, 38);
  if (block.length < 38 || (block[0] & 0x7F) != 0) return null;
  final info = block.sublist(4);
  final rate = (info[10] << 12) | (info[11] << 4) | (info[12] >> 4);
  final channels = ((info[12] >> 1) & 0x07) + 1;
  final bits = (((info[12] & 0x01) << 4) | (info[13] >> 4)) + 1;
  final total = ((info[13] & 0x0F) * 4294967296) +
      ((info[14] << 24) | (info[15] << 16) | (info[16] << 8) | info[17]);
  return AudioFormatInfo(
    container: AudioContainer.flac,
    channels: channels,
    sampleRate: rate == 0 ? null : rate,
    bitsPerSample: bits,
    duration: rate == 0 || total == 0
        ? null
        : Duration(microseconds: (total * 1000000 / rate).round()),
  );
}
