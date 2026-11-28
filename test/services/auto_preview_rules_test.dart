import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:daw_project_manager/services/associated_audio/associated_audio_service.dart';
import 'package:daw_project_manager/services/associated_audio/audio_roles.dart';
import 'package:daw_project_manager/services/auto_preview_rules.dart';
import 'package:daw_project_manager/services/preview_reference_repair.dart';
import 'package:daw_project_manager/utils/audio_format_info.dart';

import '../helpers/test_factories.dart';

/// v3.0.6 — automatic previews, from a real library: fourteen Pro Tools
/// sessions sharing one "Bounced Files" folder all got "Extra Groove.mp3",
/// and nine sessions' automatic previews were 10-channel Atmos bounces.
/// A preview the user chose is never judged by these rules.
void main() {
  final folder = p.join('/Volumes', 'G', 'Pro Tools Session folder');

  String session(String sub, String name) => p.join(folder, sub, name);
  String bounce(String sub, String name) =>
      p.join(folder, sub, 'Bounced Files', name);

  group('previewNameMatchesSession', () {
    test('a file named after its session matches', () {
      expect(
          previewNameMatchesSession(
              bounce('Asward', 'Ghetto In the Sky  Dolby Atmos Asward 2_1.wav'),
              session('Asward', 'Dolby Atmos Asward 2.ptx')),
          isTrue);
      expect(
          previewNameMatchesSession(
              bounce('Asward', 'Ghetto In the Sky  Dolby Atmos Asward 2_1.wav'),
              session('Asward', 'Ghetto In the Sky  Dolby Atmos Asward 2.ptx')),
          isTrue);
    });

    test('version words at the end of a session name are ignored', () {
      expect(
          previewNameMatchesSession(
              bounce('NLHSA', 'Never Let Her Slip Away  Dolby Atmos  2024_2.aif'),
              session('NLHSA', 'Never Let Her Slip Away  Dolby Atmos  2024_1.ptx')),
          isTrue);
      expect(sessionNameCore('Song Mix 5.recovered.ptx'), 'song mix');
    });

    test('another song\'s file does not match', () {
      expect(
          previewNameMatchesSession(bounce('Miles', 'Extra Groove.mp3'),
              session('Miles', 'Miles  - Afrobeat.Mix-Track 6.ptx')),
          isFalse);
    });

    test('words match whole: "Mix" is not inside "Remix"', () {
      expect(
          previewNameMatchesSession(
              p.join('/x', 'Remixes.wav'), p.join('/x', 'Mix.ptx')),
          isFalse);
    });
  });

  group('object bounces are parts of a mix, not the song', () {
    test('"_Object 13-14" is a stem, so never an automatic preview', () {
      final f = bounce('Asward',
          'Ghetto In the Sky  Dolby Atmos Asward 2_Object 13-14.wav');
      expect(classifyAudioRole(f), AudioRole.stem);
      expect(
          autoPreviewProblem(f, session('Asward', 'Dolby Atmos Asward 2.ptx'),
              sharedFolder: false),
          'stem');
    });

    test('"Objective Mix" and "Object Lessons" are not objects', () {
      expect(classifyAudioRole('/x/Objective Mix.wav'), AudioRole.mix);
      expect(classifyAudioRole('/x/Object Lessons.wav'), AudioRole.other);
    });
  });

  group('autoPreviewProblem', () {
    const tenCh = AudioFormatInfo(
        container: AudioContainer.aiff, channels: 10, sampleRate: 96000);
    const stereo = AudioFormatInfo(
        container: AudioContainer.wav, channels: 2, sampleRate: 48000);

    test('multichannel goes, stereo stays', () {
      final s = session('Help', 'WITH A LITTLE HELP  Dolby Atmos 2023.ptx');
      final f = bounce('Help', 'WITH A LITTLE HELP.aif');
      expect(autoPreviewProblem(f, s, sharedFolder: false, format: tenCh),
          'multichannel');
      expect(autoPreviewProblem(f, s, sharedFolder: false, format: stereo),
          isNull);
    });

    test('in a shared folder, another session\'s file goes', () {
      final s = session('Miles', 'Miles  - Afrobeat.Mix-Track 6.ptx');
      final f = bounce('Miles', 'Extra Groove.mp3');
      expect(autoPreviewProblem(f, s, sharedFolder: true),
          'sharedFolderMismatch');
      // In a folder of its own, any bounce will do, as before.
      expect(autoPreviewProblem(f, s, sharedFolder: false), isNull);
    });
  });

  group('PreviewReferenceRepair with today\'s rules', () {
    const tenCh = AudioFormatInfo(
        container: AudioContainer.aiff, channels: 10, sampleRate: 96000);
    bool here(String _) => true;
    bool notCloud(String _) => false;

    test('a 10-channel automatic preview is cleared', () {
      final project = TestFactories.makeProject(
        dawType: 'Pro Tools',
        filePath: session('Help', 'WITH A LITTLE HELP  Dolby Atmos 2023.ptx'),
        previewSongAutoPath: bounce('Help', 'WITH A LITTLE HELP.aif'),
      );
      final fixed = PreviewReferenceRepair.repair(project,
          fileExists: here, isCloudOnly: notCloud, readFormat: (_) => tenCh)!;
      expect(fixed.previewSongAutoPath, isNull);
    });

    test('a manual preview is never judged, even 10-channel', () {
      final project = TestFactories.makeProject(
        dawType: 'Pro Tools',
        filePath: session('Help', 'WITH A LITTLE HELP  Dolby Atmos 2023.ptx'),
        previewSongPath: bounce('Help', 'WITH A LITTLE HELP.aif'),
        previewSongFileName: 'WITH A LITTLE HELP.aif',
      );
      expect(
          PreviewReferenceRepair.repair(project,
              fileExists: here,
              isCloudOnly: notCloud,
              readFormat: (_) => tenCh,
              sharedSessionFolder: true),
          isNull);
    });

    test('a shared-folder mismatch is cleared; a named file is kept', () {
      final miles = TestFactories.makeProject(
        dawType: 'Pro Tools',
        filePath: session('Miles', 'Miles  - Afrobeat.Mix-Track 6.ptx'),
        previewSongAutoPath: bounce('Miles', 'Extra Groove.mp3'),
      );
      expect(
          PreviewReferenceRepair.repair(miles,
                  fileExists: here,
                  isCloudOnly: notCloud,
                  sharedSessionFolder: true)!
              .previewSongAutoPath,
          isNull);
      final asward = TestFactories.makeProject(
        dawType: 'Pro Tools',
        filePath: session('Asward', 'Dolby Atmos Asward 2.ptx'),
        previewSongAutoPath:
            bounce('Asward', 'Ghetto In the Sky  Dolby Atmos Asward 2_1.wav'),
      );
      expect(
          PreviewReferenceRepair.repair(asward,
              fileExists: here,
              isCloudOnly: notCloud,
              sharedSessionFolder: true),
          isNull);
    });

    test('a file on a drive that is not connected is not judged by header',
        () {
      var read = false;
      final project = TestFactories.makeProject(
        dawType: 'Pro Tools',
        filePath: session('Help', 'WITH A LITTLE HELP  Dolby Atmos 2023.ptx'),
        previewSongAutoPath: bounce('Help', 'WITH A LITTLE HELP.aif'),
      );
      expect(
          PreviewReferenceRepair.repair(project,
              fileExists: (_) => false,
              isCloudOnly: notCloud,
              readFormat: (_) {
                read = true;
                return tenCh;
              }),
          isNull);
      expect(read, isFalse);
    });

    test('a cloud-only file is never opened', () {
      var read = false;
      final project = TestFactories.makeProject(
        dawType: 'Pro Tools',
        filePath: session('Help', 'WITH A LITTLE HELP  Dolby Atmos 2023.ptx'),
        previewSongAutoPath: bounce('Help', 'WITH A LITTLE HELP.aif'),
      );
      PreviewReferenceRepair.repair(project,
          fileExists: here,
          isCloudOnly: (_) => true,
          readFormat: (_) {
            read = true;
            return tenCh;
          });
      expect(read, isFalse);
    });
  });

  group('bestStereoPreviewFrom', () {
    final s = session('Song', 'Song Atmos Master.ptx');
    const stereo = AudioFormatInfo(
        container: AudioContainer.wav, channels: 2, sampleRate: 48000);
    const twelve = AudioFormatInfo(
        container: AudioContainer.wav, channels: 12, sampleRate: 48000);

    AssociatedAudioFile file(String path, AudioRole role,
            {AudioFormatInfo? format = stereo,
            AudioOrigin origin = AudioOrigin.discovered,
            int modified = 0}) =>
        AssociatedAudioFile(
            path: path,
            origin: origin,
            role: role,
            format: format,
            modifiedMs: modified);

    AssociatedAudioReport report(List<AssociatedAudioFile> files) =>
        AssociatedAudioReport(
          sessionPaths: [s],
          folders: [p.dirname(s)],
          confirmed: const [],
          discovered: files,
          unreadableSessions: [s],
        );

    test('a stereo master beats a mix, a bounce and a newer render', () {
      final best = bestStereoPreviewFrom(
          report([
            file(bounce('Song', 'Song bounce.wav'), AudioRole.bounce,
                modified: 9),
            file(p.join(p.dirname(s), 'Song Mix.wav'), AudioRole.mix),
            file(p.join(p.dirname(s), 'Song Master.wav'), AudioRole.master),
          ]),
          sessionPath: s,
          sharedFolder: false);
      expect(p.basename(best!.path), 'Song Master.wav');
    });

    test('never a stem, a session clip, ADM, multichannel or nameless file',
        () {
      expect(
          bestStereoPreviewFrom(
              report([
                file('/a/Song_vocals_stem.wav', AudioRole.stem),
                file('/a/Audio Files/Kick.wav', AudioRole.sessionClip),
                file('/a/Song ADM.wav', AudioRole.admMaster),
                file('/a/Song Master 714.wav', AudioRole.master,
                    format: twelve),
                file('/a/Take 3.wav', AudioRole.other),
              ]),
              sessionPath: s,
              sharedFolder: false),
          isNull);
    });

    test('in a shared folder only a file named after the session', () {
      final r = report([
        file(bounce('Song', 'Extra Groove.mp3'), AudioRole.bounce,
            format: null),
        file(bounce('Song', 'Song Atmos Master stereo.wav'), AudioRole.master),
      ]);
      expect(
          p.basename(
              bestStereoPreviewFrom(r, sessionPath: s, sharedFolder: true)!
                  .path),
          'Song Atmos Master stereo.wav');
      expect(
          bestStereoPreviewFrom(
              report([
                file(bounce('Song', 'Extra Groove.mp3'), AudioRole.bounce,
                    format: null),
              ]),
              sessionPath: s,
              sharedFolder: true),
          isNull);
    });

    test('a folder the user added must name the session', () {
      expect(
          bestStereoPreviewFrom(
              report([
                file('/album/Other Song Master.wav', AudioRole.master,
                    origin: AudioOrigin.addedFolder),
              ]),
              sessionPath: s,
              sharedFolder: false),
          isNull);
      expect(
          bestStereoPreviewFrom(
                  report([
                    file('/album/Song Atmos Master (stereo).wav',
                        AudioRole.master,
                        origin: AudioOrigin.addedFolder),
                  ]),
                  sessionPath: s,
                  sharedFolder: false)
              ?.path,
          '/album/Song Atmos Master (stereo).wav');
    });

    test('a compressed file with no header counts as stereo', () {
      expect(
          bestStereoPreviewFrom(
                  report([
                    file('/a/Bounced Files/Song Atmos Master.mp3',
                        AudioRole.master,
                        format: null),
                  ]),
                  sessionPath: s,
                  sharedFolder: false)
              ?.path,
          '/a/Bounced Files/Song Atmos Master.mp3');
    });
  });
}
