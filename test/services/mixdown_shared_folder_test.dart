import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:daw_project_manager/services/mixdown_detector_service.dart';

import '../helpers/audio_file_builder.dart';
import '../helpers/test_factories.dart';

/// v3.0.6 — a bounce folder shared by several sessions no longer hands every
/// one of them the same newest file (a real library had fourteen Pro Tools
/// sessions all previewing "Extra Groove.mp3"). In a folder of its own,
/// detection is unchanged.
void main() {
  late Directory root;
  setUp(() async => root = await Directory.systemTemp.createTemp('shared_'));
  tearDown(() async => root.delete(recursive: true));

  Future<String> session(String name) async {
    final f = File(p.join(root.path, name));
    await f.writeAsBytes([1, 2, 3]);
    return f.path;
  }

  Future<void> bounce(String name, {int channels = 2}) async {
    final f = File(p.join(root.path, 'Bounced Files', name));
    await f.parent.create(recursive: true);
    await f.writeAsBytes(AudioFileBuilder.wav(channels: channels, frames: 8));
  }

  test('shared folder: another song\'s bounce is not picked', () async {
    final track6 = await session('Afrobeat Mix-Track 6.ptx');
    await session('Afrobeat Mix-Track 7.ptx');
    await bounce('Extra Groove.wav');
    final project =
        TestFactories.makeProject(filePath: track6, dawType: 'Pro Tools');
    expect(MixdownDetectorService.findLatestMixdown(project), isNull);
  });

  test('shared folder: the bounce named after the session is picked',
      () async {
    final track6 = await session('Afrobeat Mix-Track 6.ptx');
    await session('Afrobeat Mix-Track 7.ptx');
    await bounce('Extra Groove.wav');
    await bounce('Afrobeat Mix-Track 6 stereo.wav');
    final project =
        TestFactories.makeProject(filePath: track6, dawType: 'Pro Tools');
    expect(p.basename(MixdownDetectorService.findLatestMixdown(project)!.path),
        'Afrobeat Mix-Track 6 stereo.wav');
  });

  test('a folder with one session picks its newest bounce, as before',
      () async {
    final only = await session('Song.ptx');
    await bounce('Extra Groove.wav');
    final project =
        TestFactories.makeProject(filePath: only, dawType: 'Pro Tools');
    expect(p.basename(MixdownDetectorService.findLatestMixdown(project)!.path),
        'Extra Groove.wav');
  });

  test('AppleDouble companions are not counted as sessions', () async {
    final only = await session('Song.ptx');
    await File(p.join(root.path, '._Song.ptx')).writeAsBytes([0]);
    expect(MixdownDetectorService.sessionFolderIsShared(only), isFalse);
  });

  test('a multichannel bounce is never picked, shared folder or not',
      () async {
    final only = await session('Song.ptx');
    await bounce('Song.wav', channels: 10);
    final project =
        TestFactories.makeProject(filePath: only, dawType: 'Pro Tools');
    expect(MixdownDetectorService.findLatestMixdown(project), isNull);
  });
}
