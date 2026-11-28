import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:daw_project_manager/utils/audio_format_info.dart';

import '../helpers/audio_file_builder.dart';

/// v3.0.6 — what an audio file is comes from its header: channels, rate,
/// layout where stated, and an ADM master told by its chunks after the
/// audio, never by its name.
void main() {
  late Directory dir;
  setUp(() async => dir = await Directory.systemTemp.createTemp('audio_fmt_'));
  tearDown(() async => dir.delete(recursive: true));

  Future<String> write(String name, List<int> bytes) async {
    final path = p.join(dir.path, name);
    await File(path).writeAsBytes(bytes);
    return path;
  }

  test('a plain stereo WAV: two channels, no speaker layout claimed', () async {
    final path = await write('mix.wav', AudioFileBuilder.wav(frames: 48000));
    final info = (await readAudioFormat(path))!;
    expect(info.container, AudioContainer.wav);
    expect(info.channels, 2);
    expect(info.sampleRate, 48000);
    expect(info.bitsPerSample, 24);
    expect(info.duration, const Duration(seconds: 1));
    expect(info.speakerLayout, isNull,
        reason: 'no channel mask: the count is shown, not a guess');
    expect(audioFormatSummary(info), '2 ch');
    expect(info.isAdm, isFalse);
    expect(info.isMultichannel, isFalse);
  });

  test('a mask states the layout: 7.1.4 and 5.1', () async {
    final atmosBed = await write(
        'bed.wav', AudioFileBuilder.wav(channels: 12, mask: 0x2D63F, frames: 10));
    final info = readAudioFormatSync(atmosBed)!;
    expect(info.channels, 12);
    expect(info.speakerLayout, '7.1.4');
    expect(audioFormatSummary(info), '7.1.4');
    expect(info.isMultichannel, isTrue);

    final surround = readAudioFormatSync(await write(
        's.wav', AudioFileBuilder.wav(channels: 6, mask: 0x3F, frames: 10)))!;
    expect(surround.speakerLayout, '5.1');
  });

  test('a mask that disagrees with the channel count is not believed',
      () async {
    final path = await write(
        'odd.wav', AudioFileBuilder.wav(channels: 8, mask: 0x3F, frames: 10));
    final info = readAudioFormatSync(path)!;
    expect(info.speakerLayout, isNull);
    expect(audioFormatSummary(info), '8 ch');
  });

  test('a Dolby Atmos ADM BWF in RF64: chunks after the audio are found',
      () async {
    final path = await write('master.wav', AudioFileBuilder.admMaster());
    final info = (await readAudioFormat(path))!;
    expect(info.container, AudioContainer.rf64);
    expect(info.channels, 103);
    expect(info.hasAxml, isTrue);
    expect(info.hasChna, isTrue);
    expect(info.hasDolbyMetadata, isTrue);
    expect(info.isAdm, isTrue);
    expect(info.isDolbyAtmosAdm, isTrue);
    expect(info.duration, const Duration(milliseconds: 1),
        reason: 'length from ds64, not the 0xFFFFFFFF in the data header');
    expect(audioFormatSummary(info), 'Dolby Atmos ADM BWF · 103 ch');
  });

  test('BW64 without Dolby metadata is ADM, not Dolby Atmos', () async {
    final path = await write('adm.wav',
        AudioFileBuilder.admMaster(container: 'BW64', dolby: false, channels: 16));
    final info = readAudioFormatSync(path)!;
    expect(info.container, AudioContainer.bw64);
    expect(info.isAdm, isTrue);
    expect(info.isDolbyAtmosAdm, isFalse);
    expect(audioFormatSummary(info), 'ADM BWF · 16 ch');
  });

  test('the file name says nothing: an "ADM" name on a stereo file', () async {
    final path = await write(
        'Song Dolby Atmos ADM Master.wav', AudioFileBuilder.wav(frames: 10));
    final info = readAudioFormatSync(path)!;
    expect(info.isAdm, isFalse);
    expect(info.channels, 2);
  });

  test('unknown formats, empty and missing files give null', () async {
    expect(await readAudioFormat(await write('a.mp3', [0xFF, 0xFB, 1, 2])), isNull);
    expect(readAudioFormatSync(await write('e.wav', [])), isNull);
    expect(readAudioFormatSync(p.join(dir.path, 'missing.wav')), isNull);
  });
}
