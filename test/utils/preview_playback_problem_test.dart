import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:daw_project_manager/services/mixdown_detector_service.dart';
import 'package:daw_project_manager/ui/dialogs/preview_song_not_found_dialog.dart';
import 'package:daw_project_manager/utils/preview_playback_problem.dart';
import '../helpers/test_factories.dart';

void main() {
  late bool Function() originalPlaysOgg;
  setUp(() => originalPlaysOgg = MixdownDetectorService.platformPlaysOgg);
  tearDown(() => MixdownDetectorService.platformPlaysOgg = originalPlaysOgg);

  group('classifyPreviewPlaybackProblem', () {
    test('an AppleDouble file is a metadata file, even if present', () {
      expect(
        classifyPreviewPlaybackProblem(p.join('m', '._Tom2_19-02.wav'), fileExists: true),
        PreviewPlaybackProblem.metadataFile,
      );
    });

    test('a file that is not there is missing', () {
      expect(
        classifyPreviewPlaybackProblem(p.join('m', 'Song.wav'), fileExists: false),
        PreviewPlaybackProblem.missing,
      );
    });

    test('Ogg on a Mac is an unsupported format; elsewhere it is not', () {
      MixdownDetectorService.platformPlaysOgg = () => false;
      expect(
        classifyPreviewPlaybackProblem(p.join('m', 'Song.ogg'), fileExists: true),
        PreviewPlaybackProblem.unsupportedFormat,
      );
      MixdownDetectorService.platformPlaysOgg = () => true;
      expect(
        classifyPreviewPlaybackProblem(p.join('m', 'Song.ogg'), fileExists: true),
        PreviewPlaybackProblem.cannotPlay,
      );
    });

    test('a present WAV the player refused is "cannot play"', () {
      expect(
        classifyPreviewPlaybackProblem(p.join('m', 'Song.wav'), fileExists: true),
        PreviewPlaybackProblem.cannotPlay,
      );
    });
  });

  group('Ogg is left out of automatic detection where it cannot play', () {
    test('isAutoDetectableAudioPath', () {
      MixdownDetectorService.platformPlaysOgg = () => false;
      expect(MixdownDetectorService.isAutoDetectableAudioPath('a/Song.ogg'), isFalse);
      expect(MixdownDetectorService.isAutoDetectableAudioPath('a/Song.wav'), isTrue);
      // A hand-picked Ogg is still accepted.
      expect(MixdownDetectorService.isPlayableAudioPath('a/Song.ogg'), isTrue);
      MixdownDetectorService.platformPlaysOgg = () => true;
      expect(MixdownDetectorService.isAutoDetectableAudioPath('a/Song.ogg'), isTrue);
    });

    test('findLatestMixdown picks the older WAV over a newer Ogg on a Mac', () async {
      MixdownDetectorService.platformPlaysOgg = () => false;
      final dir = await Directory.systemTemp.createTemp('ogg_mac_');
      try {
        final mix = Directory(p.join(dir.path, 'Mixdown'))..createSync();
        final wav = File(p.join(mix.path, 'Song.wav'))..writeAsBytesSync([1]);
        final ogg = File(p.join(mix.path, 'Song.ogg'))..writeAsBytesSync([2]);
        wav.setLastModifiedSync(DateTime(2024, 1, 1));
        ogg.setLastModifiedSync(DateTime(2025, 1, 1));
        final project = TestFactories.makeProject(
          filePath: p.join(dir.path, 'Song.cpr'),
          dawType: 'Cubase',
        );
        expect(p.basename(MixdownDetectorService.findLatestMixdown(project)!.path), 'Song.wav');

        MixdownDetectorService.platformPlaysOgg = () => true;
        expect(p.basename(MixdownDetectorService.findLatestMixdown(project)!.path), 'Song.ogg');
      } finally {
        await dir.delete(recursive: true);
      }
    });

    test('findNewerFileInSameFolder never offers an Ogg on a Mac', () async {
      MixdownDetectorService.platformPlaysOgg = () => false;
      final dir = await Directory.systemTemp.createTemp('ogg_newer_');
      try {
        final wav = File(p.join(dir.path, 'Song v1.wav'))..writeAsBytesSync([1]);
        final ogg = File(p.join(dir.path, 'Song v2.ogg'))..writeAsBytesSync([2]);
        wav.setLastModifiedSync(DateTime(2024, 1, 1));
        ogg.setLastModifiedSync(DateTime(2025, 1, 1));
        expect(MixdownDetectorService.findNewerFileInSameFolder(wav.path), isNull);
      } finally {
        await dir.delete(recursive: true);
      }
    });
  });

  group('isStoredPreviewOf', () {
    final manual = p.join('m', 'Chosen.wav');
    final auto = p.join('m', 'Auto.wav');

    test('matches the manual or auto preview only', () {
      final project = TestFactories.makeProject(
        previewSongPath: manual,
        previewSongAutoPath: auto,
      );
      expect(isStoredPreviewOf(project, manual), isTrue);
      expect(isStoredPreviewOf(project, auto), isTrue);
      // A release track or playlist file must never rewrite the preview.
      expect(isStoredPreviewOf(project, p.join('m', 'Other.wav')), isFalse);
    });

    test('a project with no preview matches nothing', () {
      expect(isStoredPreviewOf(TestFactories.makeProject(), manual), isFalse);
    });
  });
}
