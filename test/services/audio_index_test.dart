import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:daw_project_manager/services/associated_audio/associated_audio_service.dart';
import 'package:daw_project_manager/services/associated_audio/audio_index_jobs.dart';
import 'package:daw_project_manager/services/associated_audio/audio_index_summary.dart';
import 'package:daw_project_manager/services/associated_audio/audio_roles.dart';
import 'package:daw_project_manager/utils/audio_format_info.dart';
import 'package:daw_project_manager/utils/cloud_file.dart';

import '../helpers/audio_file_builder.dart';
import '../helpers/test_factories.dart';

/// The real disk, counting what is opened and pretending some files are
/// cloud-only — so the tests can hold the index to "only what changed is
/// read" and "nothing in the cloud is opened".
class CountingIo extends AudioIndexIo {
  CountingIo({this.cloud = const {}});

  final Set<String> cloud;
  final headerReads = <String>[];
  final sessionReads = <String>[];

  @override
  bool isCloudOnly(String path) => cloud.contains(p.basename(path));

  @override
  AudioFormatInfo? readFormat(String path) {
    if (isCloudOnly(path)) fail('opened a cloud-only file: $path');
    headerReads.add(p.basename(path));
    return super.readFormat(path);
  }

  @override
  List<SessionAudioRef>? readSession(String path) {
    if (isCloudOnly(path)) fail('opened a cloud-only session: $path');
    sessionReads.add(p.basename(path));
    return super.readSession(path);
  }
}

/// v3.0.6 — the audio index: read once, then only what changed; nothing in
/// the cloud is opened; an offline drive keeps what was known.
void main() {
  late Directory root;
  late String project;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('audio_index_');
    project = p.join(root.path, 'Song');
  });
  tearDown(() async => root.delete(recursive: true));

  Future<File> write(String rel, List<int> bytes) async {
    final f = File(p.joinAll([project, ...rel.split('/')]));
    await f.parent.create(recursive: true);
    await f.writeAsBytes(bytes);
    return f;
  }

  Future<String> montage() async => (await write(
          'Song.mon',
          AudioFileBuilder.waveLabMontage([
            ('admM', '/Volumes/Old/Song ADM.wav'),
            ('admM', 'Song ADM.wav'),
            ('P8\x00\x00', '/Volumes/Old/Song/audio/bed.wav|audio/bed.wav'),
            ('P8\x00\x00', '/Volumes/Old/Song/audio/gone.wav|audio/gone.wav'),
          ])))
      .path;

  AssociatedAudioReport index(String session, CountingIo io,
          {AssociatedAudioReport? previous}) =>
      indexProjectAudio(
        sessionPaths: [session],
        folders: [project],
        previous: previous,
        io: io,
      );

  test('the second pass reads nothing that hasn\'t changed', () async {
    final session = await montage();
    await write('audio/bed.wav', AudioFileBuilder.wav(channels: 10, frames: 4));
    await write('Song ADM.wav', AudioFileBuilder.admMaster());
    await write('Song Master.wav', AudioFileBuilder.wav(frames: 4));

    final first = index(session, CountingIo());
    expect(first.confirmed.where((f) => f.exists).map((f) => f.fileName),
        unorderedEquals(['bed.wav', 'Song ADM.wav']));
    expect(first.missing.single.fileName, 'gone.wav');
    expect(first.discovered.single.fileName, 'Song Master.wav');
    expect(first.hasAdm, isTrue);

    // Through JSON, as the cache keeps it.
    final cached =
        AssociatedAudioReport.fromJson(jsonDecode(jsonEncode(first.toJson())))!;
    final io = CountingIo();
    final second = index(session, io, previous: cached);
    expect(io.sessionReads, isEmpty, reason: 'the montage is unchanged');
    expect(io.headerReads, isEmpty, reason: 'no audio file changed');
    expect(second.confirmed.firstWhere((f) => f.fileName == 'Song ADM.wav').format,
        first.confirmed.firstWhere((f) => f.fileName == 'Song ADM.wav').format);
    expect(second.hasAdm, isTrue);

    // A new file and a changed one: only those two are opened.
    await write('Song Master.wav', AudioFileBuilder.wav(frames: 400));
    await write('Renders/Song Binaural.wav', AudioFileBuilder.wav(frames: 4));
    final io3 = CountingIo();
    final third = index(session, io3, previous: second);
    expect(io3.headerReads,
        unorderedEquals(['Song Master.wav', 'Song Binaural.wav']));
    expect(io3.sessionReads, isEmpty);
    expect(third.discovered.map((f) => f.fileName),
        unorderedEquals(['Song Master.wav', 'Song Binaural.wav']));
  });

  test('a changed session is read again', () async {
    final session = await montage();
    await write('audio/bed.wav', AudioFileBuilder.wav(frames: 4));
    final first = index(session, CountingIo());
    // Saved again in WaveLab: a different size.
    await write(
        'Song.mon',
        AudioFileBuilder.waveLabMontage([
          ('P8\x00\x00', '/Volumes/Old/Song/audio/bed.wav|audio/bed.wav'),
        ]));
    final io = CountingIo();
    final second = index(session, io, previous: first);
    expect(io.sessionReads, ['Song.mon']);
    expect(second.missing, isEmpty);
    expect(io.headerReads, isEmpty, reason: 'bed.wav itself is unchanged');
  });

  test('cloud-only files and sessions are listed, never opened', () async {
    final session = await montage();
    await write('audio/bed.wav', AudioFileBuilder.wav(frames: 4));
    await write('Song Master.wav', AudioFileBuilder.wav(frames: 4));
    final report = index(
        session, CountingIo(cloud: {'Song Master.wav', 'bed.wav'}));
    final master =
        report.discovered.firstWhere((f) => f.fileName == 'Song Master.wav');
    expect(master.cloudOnly, isTrue);
    expect(master.format, isNull);

    final cloudSession = index(session, CountingIo(cloud: {'Song.mon'}));
    expect(cloudSession.cloudOnlySessions, [session]);
    expect(cloudSession.confirmed, isEmpty);
    expect(cloudSession.unreadableSessions, isEmpty,
        reason: 'not unreadable: deliberately not read');
  });

  test('a file downloaded since is read on the next pass', () async {
    final session = await montage();
    await write('Song Master.wav', AudioFileBuilder.wav(frames: 4));
    final first =
        index(session, CountingIo(cloud: {'Song Master.wav'}));
    final io = CountingIo();
    final second = index(session, io, previous: first);
    expect(io.headerReads, contains('Song Master.wav'));
    expect(second.discovered.firstWhere((f) => f.fileName == 'Song Master.wav')
        .format?.channels, 2);
  });

  test('a drive that is not connected keeps what was known', () async {
    final session = await montage();
    await write('Song Master.wav', AudioFileBuilder.wav(frames: 4));
    final first = index(session, CountingIo());
    await Directory(project).rename(p.join(root.path, 'Unplugged'));
    final second = index(session, CountingIo(), previous: first);
    expect(second.offlineFolders, [project]);
    expect(second.discovered.map((f) => f.fileName), ['Song Master.wav']);
    expect(second.unreadableSessions, isEmpty,
        reason: 'the session\'s last reading still stands');
    expect(second.missing.map((f) => f.fileName),
        first.missing.map((f) => f.fileName),
        reason: 'out of reach is not missing');
    expect(second.confirmed.length, first.confirmed.length);
  });

  test('summaries and filters', () async {
    final session = await montage();
    await write('Song ADM.wav', AudioFileBuilder.admMaster());
    final summary = AudioIndexSummary.of(index(session, CountingIo()));
    expect(summary.hasAdm, isTrue);
    expect(summary.missing, 2, reason: 'bed.wav and gone.wav are not here');
    final back = AudioIndexSummary.decode(summary.encode())!;
    expect(back.hasAdm, isTrue);
    expect(back.missing, 2);
    expect(audioFilterMatches(AudioFilter.hasAdm, back), isTrue);
    expect(audioFilterMatches(AudioFilter.missingAudio, back), isTrue);
    expect(audioFilterMatches(AudioFilter.hasAudio, back), isTrue);
    expect(audioFilterMatches(AudioFilter.notIndexed, back), isFalse);
    expect(audioFilterMatches(AudioFilter.notIndexed, null), isTrue);
    expect(audioFilterMatches(AudioFilter.hasAudio, null), isFalse);
  });

  test('format JSON round trip', () {
    const f = AudioFormatInfo(
      container: AudioContainer.rf64,
      channels: 103,
      sampleRate: 48000,
      bitsPerSample: 24,
      duration: Duration(milliseconds: 1234),
      hasAxml: true,
      hasChna: true,
      hasDolbyMetadata: true,
    );
    expect(AudioFormatInfo.fromJson(jsonDecode(jsonEncode(f.toJson()))), f);
    expect(AudioFormatInfo.fromJson({'c': 'nonsense'}), isNull);
  });

  test('jobs: stacks through their versions; archived and audio rows left out',
      () {
    final stack = TestFactories.makeProject(
        id: 'stack', filePath: p.join('/lib', 'Song'), isVirtual: true);
    final v1 = TestFactories.makeProject(
        id: 'v1', filePath: p.join('/lib', 'Song', 'A', 'Song.ptx'))
        .copyWith(stackId: 'stack');
    final plain =
        TestFactories.makeProject(id: 'plain', filePath: p.join('/lib', 'B', 'B.mon'));
    final wav =
        TestFactories.makeProject(id: 'wav', filePath: p.join('/lib', 'Master.wav'));
    final archived = TestFactories.makeProject(
        id: 'arch', filePath: p.join('/lib', 'C', 'C.als'))
        .copyWith(archivePath: '/zips/C.zip', archivedAt: DateTime(2026));
    final jobs = audioIndexJobs([stack, plain, wav, archived], [stack, v1, plain, wav, archived]);
    expect(jobs.map((j) => j.projectId), ['stack', 'plain']);
    expect(jobs.first.sessions, [v1.filePath]);
    expect(jobs.first.folders, [p.join('/lib', 'Song', 'A')]);
  });

  test('roles survive the cache', () async {
    final session = await montage();
    await write('Song ADM.wav', AudioFileBuilder.admMaster());
    final report = index(session, CountingIo());
    final back =
        AssociatedAudioReport.fromJson(jsonDecode(jsonEncode(report.toJson())))!;
    expect(back.confirmed.firstWhere((f) => f.fileName == 'Song ADM.wav').role,
        AudioRole.admMaster);
    expect(back.missing.map((f) => f.fileName), contains('gone.wav'));
  });

  test('macOS cloud flag', () {
    expect(statSaysCloudOnly(flags: kMacDatalessFlag), isTrue);
    expect(statSaysCloudOnly(flags: 0), isFalse);
    expect(statSaysCloudOnly(flags: 0x20), isFalse);
  });
}
