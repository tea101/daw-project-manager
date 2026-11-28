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

  group('previewNameReliablyMatches (strict)', () {
    test('a file named after its session matches', () {
      expect(
          previewNameReliablyMatches(
              bounce('Asward', 'Ghetto In the Sky  Dolby Atmos Asward 2_1.wav'),
              session('Asward', 'Dolby Atmos Asward 2.ptx')),
          isTrue);
      expect(
          previewNameReliablyMatches(
              bounce('NLHSA', 'Never Let Her Slip Away  Dolby Atmos.aif'),
              session('NLHSA', 'Never Let Her Slip Away  Dolby Atmos  2024_1.ptx')),
          isTrue,
          reason: 'version words at the end of a session name may be absent');
      expect(sessionNameCore('Song Mix 5.recovered.ptx'), 'song mix');
    });

    test('a file of another version of the song does not match', () {
      expect(
          previewNameReliablyMatches(
              bounce('Paper', 'Paper Moons MIX14.wav'),
              session('Paper', 'Paper Moons MIX13.ptx')),
          isFalse);
      expect(
          previewNameReliablyMatches(
              bounce('Paper', 'Paper Moons MIX 25_Master_v1.mp3'),
              session('Paper', 'Paper Moons Mix21 Master.ptx')),
          isFalse);
      expect(
          previewNameReliablyMatches(
              bounce('Afro', 'Afrobeat Mix-Track 7.wav'),
              session('Afro', 'Afrobeat Mix-Track 6.ptx')),
          isFalse);
      expect(
          previewNameReliablyMatches(
              bounce('NLHSA', 'Never Let Her Slip Away  Dolby Atmos  2024_2.aif'),
              session('NLHSA', 'Never Let Her Slip Away  Dolby Atmos  2024_1.ptx')),
          isFalse);
    });

    test('a version number on a session without one is fine', () {
      expect(
          previewNameReliablyMatches(p.join('/a', 'Lantern_Master_MIX v35.mp3'),
              p.join('/a', 'Lantern [48k Album].mon')),
          isTrue);
    });

    test('another song\'s file does not match', () {
      expect(
          previewNameReliablyMatches(bounce('Miles', 'Extra Groove.mp3'),
              session('Miles', 'Miles  - Afrobeat.Mix-Track 6.ptx')),
          isFalse);
      expect(
          previewNameReliablyMatches(
              p.join('/a', 'Northern Road mix.wav'),
              p.join('/a', 'Harbour Lights Dub Master V1[48k Album].mon')),
          isFalse);
      expect(
          previewNameReliablyMatches(p.join('/a', 'Hollow Hills_Master_01.wav'),
              p.join('/a', 'Moonlit.mon')),
          isFalse);
    });

    test('a session named only in generic words never matches', () {
      for (final name in ['Mix 2.ptx', 'Untitled.als', 'For Website.mon',
          'Logic Atmos Project.logicx', 'Master.mon']) {
        expect(
            previewNameReliablyMatches(p.join('/a', 'Master.wav'),
                p.join('/a', name)),
            isFalse,
            reason: name);
      }
      expect(significantSessionWords('Mix 2 [48k Album].ptx'), ['2']);
      expect(
          previewNameReliablyMatches(
              p.join('/a', 'Mix 2.wav'), p.join('/a', 'Mix 2.ptx')),
          isFalse,
          reason: 'a lone number is no song name');
    });

    test('words match whole: "Light" is not inside "Lightship"', () {
      expect(
          previewNameReliablyMatches(p.join('/x', 'Harbour Lightship Mix.wav'),
              p.join('/x', 'Harbour Light.ptx')),
          isFalse);
    });
  });

  group('isPartOfMix', () {
    const mono = AudioFormatInfo(
        container: AudioContainer.wav, channels: 1, sampleRate: 48000);
    test('instrument and voice groups, stems and backing tracks', () {
      for (final name in [
        'Vocals_Harbour Lights - Final Master Rev 1.wav',
        'Backing Track of Harbour Lights.mp3',
        'Harbour Lights Drums.wav',
        'Harbour Lights Instrumental.wav',
        'Harbour Lights Acapella.wav',
        'Harbour Lights_Object 13-14.wav',
        'Harbour Lights Stems.wav',
      ]) {
        expect(isPartOfMix(p.join('/a', name)), isTrue, reason: name);
      }
    });

    test('one channel of a split, or a mono file', () {
      expect(isPartOfMix('/a/Master Audio-FZ.R.wav'), isTrue);
      expect(isPartOfMix('/a/Harbour Master _V6-FZ_1.LFE.wav'), isTrue);
      expect(isPartOfMix('/a/Harbour Master PRINT-cm-FZ.C.wav'), isTrue);
      expect(isPartOfMix('/a/Harbour Master.wav', format: mono), isTrue);
    });

    test('a DAW\'s own backup or working copy', () {
      expect(
          isPartOfMix(p.join('/a', 'Harbour.mon', 'system.mon', 'edits',
              'Harbour_2.wav')),
          isTrue);
    });

    test('the song itself is not a part', () {
      for (final name in [
        'Harbour Lights Master.wav',
        'Harbour Lights Mix 2.wav',
        'Harbour Lights (stereo).wav',
        'Harbour Lights Dolby Atmos Mix_2.0 Direct.wav',
        'Basement Tapes Master.wav',
        'Keystone Mix.wav',
      ]) {
        expect(isPartOfMix(p.join('/a', name)), isFalse, reason: name);
      }
    });
  });

  group('autoPreviewFitsSession', () {
    final s = session('Harbour', 'Harbour Lights.ptx');
    test('named after the session: yes, even in a shared folder', () {
      expect(
          autoPreviewFitsSession(bounce('Harbour', 'Harbour Lights Mix.wav'), s,
              sharedFolder: true, inSessionBounceFolder: false),
          isTrue);
    });
    test('another name: only from the session\'s own bounce folder, unshared',
        () {
      final f = bounce('Harbour', 'Mixdown 3.wav');
      expect(autoPreviewFitsSession(f, s, sharedFolder: false), isTrue);
      expect(autoPreviewFitsSession(f, s, sharedFolder: true), isFalse);
      expect(
          autoPreviewFitsSession(f, s,
              sharedFolder: false, inSessionBounceFolder: false),
          isFalse);
    });
    test('a part of the mix never, whatever its name', () {
      expect(
          autoPreviewFitsSession(
              bounce('Harbour', 'Vocals_Harbour Lights.wav'), s,
              sharedFolder: false),
          isFalse);
    });
  });

  group('isInSessionBounceFolder', () {
    const names = ['Bounced Files', 'Bounces', 'Mixdown'];
    test('directly in a bounce folder beside the session', () {
      expect(
          isInSessionBounceFolder(bounce('Harbour', 'x.wav'),
              session('Harbour', 'Harbour.ptx'), names),
          isTrue);
      expect(
          isInSessionBounceFolder(p.join('/a', 'Song.logicx', 'Bounces', 'x.wav'),
              p.join('/a', 'Song.logicx'), names),
          isTrue);
    });
    test('anywhere else is not', () {
      expect(
          isInSessionBounceFolder(p.join(folder, 'Harbour', 'x.wav'),
              session('Harbour', 'Harbour.ptx'), names),
          isFalse);
      expect(
          isInSessionBounceFolder(
              p.join(folder, 'Other', 'Bounced Files', 'x.wav'),
              session('Harbour', 'Harbour.ptx'), names),
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
          'notReliablyThisSession');
      // In a folder of its own, its own bounce folder's file will do.
      expect(autoPreviewProblem(f, s, sharedFolder: false), isNull);
      // Found anywhere else, it must be named after the session.
      expect(
          autoPreviewProblem(f, s,
              sharedFolder: false, inSessionBounceFolder: false),
          'notReliablyThisSession');
    });

    test('parts of the mix go', () {
      final s = session('Harbour', 'Harbour Lights Dolby Atmos.ptx');
      expect(
          autoPreviewProblem(
              p.join(folder, 'Harbour',
                  'Vocals_Harbour Lights - Final Master Rev 1.wav'),
              s,
              sharedFolder: false),
          'partOfMix');
      const mono = AudioFormatInfo(
          container: AudioContainer.wav, channels: 1, sampleRate: 48000);
      expect(
          autoPreviewProblem(bounce('Harbour', 'Harbour Lights Master.wav'), s,
              sharedFolder: false, format: mono),
          'partOfMix');
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
    final s = session('Harbour', 'Harbour Lights Atmos Master.ptx');
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
            file(bounce('Harbour', 'Harbour Lights bounce.wav'), AudioRole.bounce,
                modified: 9),
            file(p.join(p.dirname(s), 'Harbour Lights Mix.wav'), AudioRole.mix),
            file(p.join(p.dirname(s), 'Harbour Lights Master.wav'), AudioRole.master),
          ]),
          sessionPath: s,
          sharedFolder: false);
      expect(p.basename(best!.path), 'Harbour Lights Master.wav');
    });

    test('never a stem, a session clip, ADM, multichannel or nameless file',
        () {
      expect(
          bestStereoPreviewFrom(
              report([
                file('/a/Harbour Lights_vocals_stem.wav', AudioRole.stem),
                file('/a/Audio Files/Kick.wav', AudioRole.sessionClip),
                file('/a/Harbour Lights ADM.wav', AudioRole.admMaster),
                file('/a/Harbour Lights Master 714.wav', AudioRole.master,
                    format: twelve),
                file('/a/Take 3.wav', AudioRole.other),
              ]),
              sessionPath: s,
              sharedFolder: false),
          isNull);
    });

    test('in a shared folder only a file named after the session', () {
      final r = report([
        file(bounce('Harbour', 'Extra Groove.mp3'), AudioRole.bounce,
            format: null),
        file(bounce('Harbour', 'Harbour Lights Atmos Master stereo.wav'), AudioRole.master),
      ]);
      expect(
          p.basename(
              bestStereoPreviewFrom(r, sessionPath: s, sharedFolder: true)!
                  .path),
          'Harbour Lights Atmos Master stereo.wav');
      expect(
          bestStereoPreviewFrom(
              report([
                file(bounce('Harbour', 'Extra Groove.mp3'), AudioRole.bounce,
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
                    file('/album/Harbour Lights Atmos Master (stereo).wav',
                        AudioRole.master,
                        origin: AudioOrigin.addedFolder),
                  ]),
                  sessionPath: s,
                  sharedFolder: false)
              ?.path,
          '/album/Harbour Lights Atmos Master (stereo).wav');
    });

    test('a compressed file with no header counts as stereo', () {
      expect(
          bestStereoPreviewFrom(
                  report([
                    file('/a/Bounced Files/Harbour Lights Atmos Master.mp3',
                        AudioRole.master,
                        format: null),
                  ]),
                  sessionPath: s,
                  sharedFolder: false)
              ?.path,
          '/a/Bounced Files/Harbour Lights Atmos Master.mp3');
    });

    test('never a mono file or one channel of a split', () {
      const mono = AudioFormatInfo(
          container: AudioContainer.wav, channels: 1, sampleRate: 48000);
      expect(
          bestStereoPreviewFrom(
              report([
                file('/a/Harbour Lights Master.wav', AudioRole.master,
                    format: mono),
                file('/a/Harbour Lights Master-FZ.R.wav', AudioRole.master),
              ]),
              sessionPath: s,
              sharedFolder: false),
          isNull);
    });

    test('even beside the session, another song\'s master is not taken', () {
      expect(
          bestStereoPreviewFrom(
              report([
                file(bounce('Harbour', 'Northern Road Master.wav'),
                    AudioRole.master),
              ]),
              sessionPath: s,
              sharedFolder: false),
          isNull);
    });
  });
}
