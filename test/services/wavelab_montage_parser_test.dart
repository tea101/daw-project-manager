import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:daw_project_manager/services/daw_parsers/wavelab_montage_parser.dart';

import '../helpers/audio_file_builder.dart';

/// v3.0.6 — a WaveLab 13 montage names its clips' sources as
/// "absolute|relative" and its ADM master in `admM` records. Built here to
/// the layout read from real montages; no real montage is in the repository.
void main() {
  const p8 = 'P8\x00\x00';

  test('reads clip sources with both paths, and the ADM master', () {
    final bytes = AudioFileBuilder.waveLabMontage([
      ('admM', '/Volumes/Old Drive/ADM/Song.wav'),
      ('admM', '../ADM/Song.wav'),
      (p8, '/Volumes/Old Drive/Proj/audio/bed_1_3.wav|audio/bed_1_3.wav'),
      (p8, '/Volumes/Old Drive/Proj/audio/Object 11_3.wav|audio/Object 11_3.wav'),
    ]);
    final parser = WaveLabMontageParser(bytes);
    expect(parser.isMontage, isTrue);
    expect(parser.version, '13.0');

    final refs = parser.readAudioReferences();
    expect(refs, hasLength(3));
    expect(refs[0].role, WaveLabAudioRole.admSource);
    expect(refs[0].absolutePath, '/Volumes/Old Drive/ADM/Song.wav');
    expect(refs[0].relativePath, '../ADM/Song.wav');
    expect(refs[1].role, WaveLabAudioRole.clipSource);
    expect(refs[1].relativePath, 'audio/bed_1_3.wav');
    expect(refs[1].candidates.first, 'audio/bed_1_3.wav',
        reason: 'relative first: it survives a renamed drive');
    expect(refs[2].fileName, 'Object 11_3.wav');
  });

  test('an ADM master with only its absolute path', () {
    final refs = WaveLabMontageParser(AudioFileBuilder.waveLabMontage([
      ('admM', '/Users/someone/Desktop/Master.wav'),
      (p8, '/x/audio/a.wav|audio/a.wav'),
    ])).readAudioReferences();
    expect(refs.first.role, WaveLabAudioRole.admSource);
    expect(refs.first.relativePath, isNull);
    expect(refs.first.candidates, ['/Users/someone/Desktop/Master.wav']);
  });

  test('a montage of one file in its own folder', () {
    final refs = WaveLabMontageParser(AudioFileBuilder.waveLabMontage([
      (p8, '/Volumes/D/Song V1.wav|Song V1.wav'),
    ])).readAudioReferences();
    expect(refs.single.relativePath, 'Song V1.wav');
  });

  test('Windows paths, repeats and non-audio text', () {
    final refs = WaveLabMontageParser(AudioFileBuilder.waveLabMontage([
      (p8, r'D:\Masters\Song.wav|Song.wav'),
      (p8, r'D:\Masters\Song.wav|Song.wav'),
      (p8, 'Track1'),
      ('admM', 'not a path'),
      ('xxxx', '/Volumes/D/Other.wav'),
    ])).readAudioReferences();
    expect(refs, hasLength(1), reason: 'repeats once; other text and tags ignored');
    expect(refs.single.absolutePath, r'D:\Masters\Song.wav');
  });

  test('text one byte out of step does not swallow the real path', () {
    // Regression: a zero byte before "/" read as the unit 0x2F00 and
    // consumed the string that starts a byte later; every real montage
    // gave no references.
    final refs = WaveLabMontageParser(AudioFileBuilder.waveLabMontage([
      (p8, '/a/b/c.wav|c.wav'),
    ])).readAudioReferences();
    expect(refs, hasLength(1));
  });

  test('not a montage: no references, never a guess', () {
    expect(
        WaveLabMontageParser(Uint8List.fromList(List.filled(200, 0x41)))
            .readAudioReferences(),
        isEmpty);
    expect(WaveLabMontageParser(Uint8List(10)).isMontage, isFalse);
  });
}
