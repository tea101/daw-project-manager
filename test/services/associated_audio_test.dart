import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:daw_project_manager/services/associated_audio/associated_audio_service.dart';
import 'package:daw_project_manager/services/associated_audio/audio_roles.dart';
import 'package:daw_project_manager/services/mixdown_detector_service.dart';
import 'package:daw_project_manager/utils/audio_format_info.dart';

import '../helpers/audio_file_builder.dart';
import '../helpers/test_factories.dart';

/// v3.0.6 — audio that belongs to a project: confirmed by its session or
/// discovered in its folder, never confused; and what may become a preview
/// automatically.
void main() {
  group('classifyAudioRole', () {
    const folder = '/p/Song';
    AudioRole role(String rel, {AudioFormatInfo? format}) =>
        classifyAudioRole(p.join(folder, rel), projectFolder: folder, format: format);

    test('names and folders', () {
      expect(role('Song Master.wav'), AudioRole.master);
      expect(role('Song Mastered v2.wav'), AudioRole.master);
      expect(role('Song Mix 3.wav'), AudioRole.mix);
      expect(role('Song Drum Stem.wav'), AudioRole.stem);
      expect(role('Stems/Drums.wav'), AudioRole.stem);
      expect(role('Audio Files/Vox_01.wav'), AudioRole.sessionClip);
      expect(role('audio/bed_1_3.wav'), AudioRole.sessionClip);
      expect(role('Bounced Files/Song.wav'), AudioRole.bounce);
      expect(role('Renders/Song.wav'), AudioRole.render);
      expect(role('Song.wav'), AudioRole.other);
      expect(role('Mixture.wav'), AudioRole.other, reason: 'whole words only');
    });

    test('an ADM master by its header only', () {
      const adm = AudioFormatInfo(
          container: AudioContainer.rf64, channels: 103, hasAxml: true, hasChna: true);
      expect(role('Song.wav', format: adm), AudioRole.admMaster);
      expect(role('Song ADM.wav'), AudioRole.other,
          reason: 'a name never makes an ADM master');
    });
  });

  group('autoPreviewRejection', () {
    test('never stems, session clips, ADM masters or multichannel', () {
      expect(autoPreviewRejection('/p/S/Stems/Bass.wav', projectFolder: '/p/S'),
          AutoPreviewRejection.stem);
      expect(autoPreviewRejection('/p/S/Audio Files/Gtr.wav', projectFolder: '/p/S'),
          AutoPreviewRejection.sessionClip);
      expect(
          autoPreviewRejection('/p/S/Bounced Files/M.wav',
              projectFolder: '/p/S',
              format: const AudioFormatInfo(
                  container: AudioContainer.wav, channels: 12)),
          AutoPreviewRejection.multichannel);
      expect(
          autoPreviewRejection('/p/S/M.wav',
              format: const AudioFormatInfo(
                  container: AudioContainer.rf64, channels: 2, hasChna: true)),
          AutoPreviewRejection.admMaster);
      expect(
          autoPreviewRejection('/p/S/Bounced Files/Mix.wav',
              projectFolder: '/p/S',
              format: const AudioFormatInfo(container: AudioContainer.wav, channels: 2)),
          isNull);
    });
  });

  test('multi-mono parts', () {
    expect(multiMonoPart('/a/Mix.L.wav')?.channel, 'L');
    expect(multiMonoPart('/a/Mix.Ltf.wav')?.group, p.join('/a', 'Mix'));
    expect(multiMonoPart('/a/Mix.wav'), isNull);
    expect(multiMonoPart('/a/Mix.final.wav'), isNull);
  });

  group('readAssociatedAudio', () {
    late Directory root;
    late String project;
    setUp(() async {
      root = await Directory.systemTemp.createTemp('assoc_audio_');
      project = p.join(root.path, 'Song');
      await Directory(p.join(project, 'audio')).create(recursive: true);
    });
    tearDown(() async => root.delete(recursive: true));

    Future<void> write(String rel, List<int> bytes) async {
      final f = File(p.joinAll([project, ...rel.split('/')]));
      await f.parent.create(recursive: true);
      await f.writeAsBytes(bytes);
    }

    test('a WaveLab montage: confirmed, missing and discovered kept apart',
        () async {
      await write('audio/bed_1_3.wav', AudioFileBuilder.wav(channels: 10, frames: 4));
      await write('audio/Object 11_3.wav', AudioFileBuilder.wav(channels: 1, frames: 4));
      await write('Song ADM.wav', AudioFileBuilder.admMaster());
      await write('Song Stereo Master.wav', AudioFileBuilder.wav(frames: 4));
      await write('._Song Stereo Master.wav', [0, 0, 0]);
      await write('Session File Backups/old.wav', AudioFileBuilder.wav(frames: 4));
      await write(
          'Song.mon',
          AudioFileBuilder.waveLabMontage([
            ('admM', '/Volumes/Gone/ADM/Song ADM original.wav'),
            ('P8\x00\x00', '/Volumes/Gone/Song/audio/bed_1_3.wav|audio/bed_1_3.wav'),
            ('P8\x00\x00',
                '/Volumes/Gone/Song/audio/Object 11_3.wav|audio/Object 11_3.wav'),
          ]));

      final report = await readAssociatedAudio(
        sessionPaths: [p.join(project, 'Song.mon')],
        folders: [project],
      );

      expect(report.unreadableSessions, isEmpty);
      final confirmed = {for (final f in report.confirmed) f.fileName: f};
      expect(confirmed.keys,
          containsAll(['bed_1_3.wav', 'Object 11_3.wav', 'Song ADM original.wav']));
      expect(confirmed['bed_1_3.wav']!.exists, isTrue,
          reason: 'found through its relative path after the drive was renamed');
      expect(confirmed['bed_1_3.wav']!.role, AudioRole.sessionClip);
      expect(confirmed['bed_1_3.wav']!.format?.channels, 10);
      expect(confirmed['Song ADM original.wav']!.exists, isFalse);
      expect(confirmed['Song ADM original.wav']!.role, AudioRole.admMaster);
      expect(report.missing.single.fileName, 'Song ADM original.wav');

      final discovered = {for (final f in report.discovered) f.fileName: f};
      expect(discovered.keys, unorderedEquals(['Song ADM.wav', 'Song Stereo Master.wav']),
          reason: 'confirmed files are not repeated; AppleDouble and backups skipped');
      expect(discovered['Song ADM.wav']!.role, AudioRole.admMaster);
      expect(discovered['Song ADM.wav']!.format!.isDolbyAtmosAdm, isTrue);
      expect(discovered['Song Stereo Master.wav']!.origin, AudioOrigin.discovered);
    });

    test('a Pro Tools session is unreadable here: folder audio only', () async {
      await write('Song.ptx', [3, 0x30, 0x30]);
      await write('Audio Files/Gtr.wav', AudioFileBuilder.wav(frames: 4));
      await write('Bounced Files/Song Mix.wav', AudioFileBuilder.wav(frames: 4));
      final report = await readAssociatedAudio(
        sessionPaths: [p.join(project, 'Song.ptx')],
        folders: [project],
      );
      expect(canReadSessionAudio(p.join(project, 'Song.ptx')), isFalse);
      expect(report.unreadableSessions, [p.join(project, 'Song.ptx')]);
      expect(report.confirmed, isEmpty);
      expect(report.discovered.map((f) => f.role),
          containsAll([AudioRole.sessionClip, AudioRole.mix]));
    });
  });

  group('automatic preview never picks the wrong thing', () {
    late Directory dir;
    setUp(() async => dir = await Directory.systemTemp.createTemp('auto_prev_'));
    tearDown(() async => dir.delete(recursive: true));

    Future<File> file(String rel, List<int> bytes, DateTime modified) async {
      // Built with the platform's separator: compared with what the
      // detector finds on disk, on Windows too.
      final f = File(p.joinAll([dir.path, ...rel.split('/')]));
      await f.parent.create(recursive: true);
      await f.writeAsBytes(bytes);
      await f.setLastModified(modified);
      return f;
    }

    test('newest ADM, multichannel and stem are passed over', () async {
      final project = TestFactories.makeProject(
          filePath: p.join(dir.path, 'Song.ptx'), dawType: 'Pro Tools');
      final t = DateTime(2026, 1, 1);
      final stereo = await file('Bounced Files/Song Mix.wav',
          AudioFileBuilder.wav(frames: 4), t);
      await file('Bounced Files/Song ADM.wav', AudioFileBuilder.admMaster(),
          t.add(const Duration(hours: 1)));
      await file('Bounced Files/Song 714.wav',
          AudioFileBuilder.wav(channels: 12, mask: 0x2D63F, frames: 4),
          t.add(const Duration(hours: 2)));
      await file('Bounced Files/Song Drum Stem.wav',
          AudioFileBuilder.wav(frames: 4), t.add(const Duration(hours: 3)));

      final picked = MixdownDetectorService.findLatestMixdown(project);
      expect(picked?.path, stereo.path);
    });

    test('nothing eligible: nothing picked', () async {
      final project = TestFactories.makeProject(
          filePath: p.join(dir.path, 'Song.mon'), dawType: 'WaveLab');
      await file('Mixdown/Song ADM.wav', AudioFileBuilder.admMaster(),
          DateTime(2026, 1, 1));
      expect(MixdownDetectorService.findLatestMixdown(project), isNull);
    });

    test('a folder the user listed is theirs: its clips may be picked',
        () async {
      final project = TestFactories.makeProject(
          filePath: p.join(dir.path, 'Song.ptx'), dawType: 'Pro Tools');
      final clip = await file('Audio Files/Song Print.wav',
          AudioFileBuilder.wav(frames: 4), DateTime(2026, 1, 1));
      expect(
          MixdownDetectorService.findLatestMixdown(project,
                  customFolders: ['Audio Files'])
              ?.path,
          clip.path);
    });
  });
}
