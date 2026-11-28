import 'dart:convert';
import 'dart:typed_data';

/// Builds small audio files with real headers for tests: plain WAV,
/// WAVE_FORMAT_EXTENSIBLE with a channel mask, and RF64/BW64 ADM masters
/// laid out as Dolby's tools write them (ds64, fmt, data, then axml, chna
/// and dbmd after the audio).
class AudioFileBuilder {
  static Uint8List _chunk(String id, List<int> body) {
    final b = BytesBuilder();
    b.add(ascii.encode(id));
    b.add(_u32(body.length));
    b.add(body);
    if (body.length.isOdd) b.addByte(0);
    return b.toBytes();
  }

  static Uint8List _u16(int v) =>
      (ByteData(2)..setUint16(0, v, Endian.little)).buffer.asUint8List();
  static Uint8List _u32(int v) =>
      (ByteData(4)..setUint32(0, v, Endian.little)).buffer.asUint8List();
  static Uint8List _u64(int v) =>
      (ByteData(8)..setUint64(0, v, Endian.little)).buffer.asUint8List();

  static Uint8List _fmt({
    required int channels,
    required int rate,
    required int bits,
    int? mask,
  }) {
    final b = BytesBuilder();
    final blockAlign = channels * bits ~/ 8;
    b.add(_u16(mask == null ? 1 : 0xFFFE));
    b.add(_u16(channels));
    b.add(_u32(rate));
    b.add(_u32(rate * blockAlign));
    b.add(_u16(blockAlign));
    b.add(_u16(bits));
    if (mask != null) {
      b.add(_u16(22));
      b.add(_u16(bits));
      b.add(_u32(mask));
      b.add(List.filled(16, 0)); // sub-format GUID; not read
    }
    return b.toBytes();
  }

  /// A RIFF/WAVE file with [frames] frames of silence.
  static Uint8List wav({
    int channels = 2,
    int rate = 48000,
    int bits = 24,
    int frames = 4800,
    int? mask,
    bool bext = false,
  }) {
    final body = BytesBuilder();
    body.add(ascii.encode('WAVE'));
    if (bext) body.add(_chunk('bext', List.filled(602, 0)));
    body.add(_chunk('fmt ', _fmt(channels: channels, rate: rate, bits: bits, mask: mask)));
    body.add(_chunk('data', List.filled(frames * channels * bits ~/ 8, 0)));
    final out = BytesBuilder();
    out.add(ascii.encode('RIFF'));
    out.add(_u32(body.length));
    out.add(body.toBytes());
    return out.toBytes();
  }

  /// An RF64 (or BW64) ADM master: ds64 with the real sizes, data marked
  /// 0xFFFFFFFF, and the ADM chunks after the audio.
  static Uint8List admMaster({
    String container = 'RF64',
    int channels = 103,
    int rate = 48000,
    int bits = 24,
    int frames = 48,
    bool dolby = true,
  }) {
    final dataSize = frames * channels * bits ~/ 8;
    final ds64 = BytesBuilder()
      ..add(_u64(0)) // riff size (not read)
      ..add(_u64(dataSize))
      ..add(_u64(frames))
      ..add(_u32(0));
    final body = BytesBuilder();
    body.add(ascii.encode('WAVE'));
    body.add(_chunk('ds64', ds64.toBytes()));
    body.add(_chunk('fmt ', _fmt(channels: channels, rate: rate, bits: bits)));
    body.add(ascii.encode('data'));
    body.add(_u32(0xFFFFFFFF));
    body.add(List.filled(dataSize, 0));
    if (dataSize.isOdd) body.addByte(0);
    body.add(_chunk('axml', utf8.encode('<ebuCoreMain/>')));
    body.add(_chunk('chna', [...(_u16(channels)), ...(_u16(channels))]));
    if (dolby) body.add(_chunk('dbmd', List.filled(16, 0)));
    final out = BytesBuilder();
    out.add(ascii.encode(container));
    out.add(_u32(0xFFFFFFFF));
    out.add(body.toBytes());
    return out.toBytes();
  }

  /// A WaveLab 13 audio montage holding only the records the reader looks
  /// at: `P8` clip sources ("absolute|relative") and `admM` ADM sources.
  /// [records] are (tag, text) pairs, tag being 'P8\x00\x00' or 'admM'.
  static Uint8List waveLabMontage(List<(String, String)> records) {
    final b = BytesBuilder();
    b.add([0x4C, 0x45, 0x33, 0x00]); // LE3\0
    b.add(List.filled(24, 0x11)); // version/flags bytes, not read
    b.add(ascii.encode('WaveLabAudioMontage13.0'));
    b.addByte(0);
    b.add(ascii.encode('{"type":1}'));
    b.add(List.filled(32, 0));
    for (final (tag, text) in records) {
      b.add(latin1.encode(tag));
      b.add(List.filled(4, 0));
      for (final unit in text.codeUnits) {
        b.add(_u16(unit));
      }
      b.add([0, 0, 0, 0]);
      b.add(List.filled(24, 0x01)); // other record fields
    }
    return b.toBytes();
  }
}
