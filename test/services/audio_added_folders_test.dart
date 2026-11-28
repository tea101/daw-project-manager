import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:daw_project_manager/services/associated_audio/associated_audio_service.dart';
import 'package:daw_project_manager/services/associated_audio/audio_index_jobs.dart';

import '../helpers/audio_file_builder.dart';
import '../helpers/test_factories.dart';

/// v3.0.6 — folders the user adds to a project's audio search, for a
/// session that keeps its audio outside its own folder (Pro Tools sessions
/// whose clips live in the client's "00_ORIGINAL…" folder, found on a real
/// library). Their files are kept apart from the project folder's, nothing
/// is guessed, and a session folder with no audio says so plainly.
void main() {
  late Directory root;
  late String sessionFolder;
  late String clientAudio;
  late String session;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('audio_added_');
    sessionFolder = p.join(root.path, 'Client', '01_SESSION_FILES', 'Song');
    clientAudio = p.join(root.path, 'Client', '00_ORIGINAL_FILES');
    await Directory(sessionFolder).create(recursive: true);
    await Directory(clientAudio).create(recursive: true);
    // A Pro Tools session: its references can't be read.
    session = p.join(sessionFolder, 'Song Atmos Master.ptx');
    await File(session).writeAsBytes([1, 2, 3]);
    await File(p.join(sessionFolder, 'WaveCache.wfm')).writeAsBytes([0]);
    await Directory(p.join(sessionFolder, 'Session File Backups'))
        .create(recursive: true);
    await File(p.join(sessionFolder, 'Session File Backups', 'x.bak.001.ptx'))
        .writeAsBytes([0]);
  });
  tearDown(() async => root.delete(recursive: true));

  Future<String> audio(String folder, String name) async {
    final f = File(p.join(folder, name));
    await f.parent.create(recursive: true);
    await f.writeAsBytes(AudioFileBuilder.wav(frames: 8));
    return f.path;
  }

  test('a session folder with no audio is said plainly, nothing guessed', () {
    final report =
        indexProjectAudio(sessionPaths: [session], folders: [sessionFolder]);
    expect(report.unreadableSessions, [session]);
    expect(report.inProjectFolders, isEmpty);
    expect(report.inAddedFolders, isEmpty);
    expect(sessionAudioLivesElsewhere(report), isTrue);
  });

  test('audio in the session folder is not "elsewhere"', () async {
    await audio(p.join(sessionFolder, 'Audio Files'), 'Bass_01.wav');
    final report =
        indexProjectAudio(sessionPaths: [session], folders: [sessionFolder]);
    expect(report.inProjectFolders, hasLength(1));
    expect(sessionAudioLivesElsewhere(report), isFalse);
  });

  test('an offline project folder is not "elsewhere": it is out of reach',
      () async {
    final report = indexProjectAudio(
      sessionPaths: [session],
      folders: [p.join(root.path, 'Unplugged Drive', 'Song')],
    );
    expect(sessionAudioLivesElsewhere(report), isFalse);
  });

  test('files in an added folder are listed apart, as addedFolder', () async {
    final bass = await audio(clientAudio, 'Bass B.wav');
    final drums = await audio(p.join(clientAudio, 'Drums'), 'Drum Prog B.wav');
    final report = indexProjectAudio(
      sessionPaths: [session],
      folders: [sessionFolder],
      addedFolders: [clientAudio],
    );
    expect(report.addedFolders, [clientAudio]);
    expect(report.inProjectFolders, isEmpty);
    expect(report.inAddedFolders.map((f) => f.path),
        unorderedEquals([bass, drums]));
    expect(report.inAddedFolders.every((f) => f.origin == AudioOrigin.addedFolder),
        isTrue);
    // Nothing is confirmed by an added folder: the session still wasn't read.
    expect(report.confirmed, isEmpty);
    // The note still says the session folder has none: the added files are
    // the user's choice of where to look, not the session's.
    expect(sessionAudioLivesElsewhere(report), isTrue);
  });

  test("a file in both the project folder and an added folder is the "
      "project's", () async {
    final clip = await audio(p.join(sessionFolder, 'Audio Files'), 'Clip.wav');
    final report = indexProjectAudio(
      sessionPaths: [session],
      folders: [sessionFolder],
      // The user added a folder that contains the session folder.
      addedFolders: [p.join(root.path, 'Client')],
    );
    final clipRows = report.discovered.where((f) => f.path == clip).toList();
    expect(clipRows, hasLength(1));
    expect(clipRows.single.origin, AudioOrigin.discovered);
  });

  test('an added folder that goes offline keeps what was known', () async {
    final bass = await audio(clientAudio, 'Bass B.wav');
    final first = indexProjectAudio(
      sessionPaths: [session],
      folders: [sessionFolder],
      addedFolders: [clientAudio],
    );
    await Directory(clientAudio).delete(recursive: true);
    final second = indexProjectAudio(
      sessionPaths: [session],
      folders: [sessionFolder],
      addedFolders: [clientAudio],
      previous: first,
    );
    expect(second.offlineFolders, contains(clientAudio));
    expect(second.inAddedFolders.map((f) => f.path), [bass]);
    // Only the added folder is offline: the session folder was searched.
    expect(sessionAudioLivesElsewhere(second), isTrue);
  });

  test('removing an added folder drops its files on the next read', () async {
    await audio(clientAudio, 'Bass B.wav');
    final first = indexProjectAudio(
      sessionPaths: [session],
      folders: [sessionFolder],
      addedFolders: [clientAudio],
    );
    final second = indexProjectAudio(
      sessionPaths: [session],
      folders: [sessionFolder],
      previous: first,
    );
    expect(second.addedFolders, isEmpty);
    expect(second.inAddedFolders, isEmpty);
  });

  test('added folders and their files survive the cache (JSON)', () async {
    await audio(clientAudio, 'Bass B.wav');
    final report = indexProjectAudio(
      sessionPaths: [session],
      folders: [sessionFolder],
      addedFolders: [clientAudio],
    );
    final back = AssociatedAudioReport.fromJson(
        jsonDecode(jsonEncode(report.toJson())))!;
    expect(back.addedFolders, [clientAudio]);
    expect(back.inAddedFolders, hasLength(1));
    expect(back.inAddedFolders.single.origin, AudioOrigin.addedFolder);
  });

  test('a report cached before added folders existed reads as none', () {
    final old = {
      'v': 1, 'sp': [session], 'fo': [sessionFolder],
      'cf': [], 'df': [], 'us': [session], 'ss': [],
    };
    final back = AssociatedAudioReport.fromJson(old)!;
    expect(back.addedFolders, isEmpty);
    expect(back.inAddedFolders, isEmpty);
  });

  test('the index jobs carry each project its own added folders', () {
    final a = TestFactories.makeProject(id: 'a', filePath: session);
    final b = TestFactories.makeProject(
        id: 'b', filePath: p.join(root.path, 'Other', 'Other.ptx'));
    final jobs = audioIndexJobs([a, b], [a, b],
        addedFolders: {'a': [clientAudio]});
    expect(jobs.firstWhere((j) => j.projectId == 'a').addedFolders,
        [clientAudio]);
    expect(jobs.firstWhere((j) => j.projectId == 'b').addedFolders, isEmpty);
  });
}
