import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:daw_project_manager/services/standalone_audio_scanner.dart';

/// v3.0.6 — standalone audio: audio in folders no DAW session owns. A
/// session's folder (and everything below it) is the session's.
void main() {
  late Directory root;
  setUp(() async => root = await Directory.systemTemp.createTemp('standalone_'));
  tearDown(() async => root.delete(recursive: true));

  Future<void> touch(String rel) async {
    final f = File(p.join(root.path, rel));
    await f.parent.create(recursive: true);
    await f.writeAsBytes([0]);
  }

  test('finds masters with no session; leaves sessions\' audio alone', () async {
    await touch('Masters/Looking for Fairies Master.wav');
    await touch('Masters/Looking for Fairies Master.aif');
    await touch('Masters/._Looking for Fairies Master.wav');
    await touch('Masters/notes.txt');
    await touch('Fairies Mix/Fairies Mix.ptx');
    await touch('Fairies Mix/Bounced Files/Fairies Mix.wav');
    await touch('Fairies Mix/Audio Files/Gtr.wav');
    await touch('Atmos/Song.mon');
    await touch('Atmos/audio/bed.wav');
    await touch('Atmos/Song ADM.wav');
    await touch('Loose/Audio Files/orphan.wav');
    await touch('Loose/Session File Backups/old.wav');

    final found = await findStandaloneAudio(root.path)
        .map((f) => p.relative(f.path, from: root.path))
        .toList();
    expect(found, unorderedEquals([
      p.join('Masters', 'Looking for Fairies Master.wav'),
      p.join('Masters', 'Looking for Fairies Master.aif'),
    ]));
  });

  test('a bundle session owns its folder too, and ignored paths are skipped',
      () async {
    await Directory(p.join(root.path, 'Logic', 'Song.logicx')).create(recursive: true);
    await touch('Logic/Song Master.wav');
    await touch('Ignored/Master.wav');
    await touch('Kept/Master.wav');
    final found = await findStandaloneAudio(root.path,
            ignoredPaths: [p.join(root.path, 'Ignored')])
        .map((f) => p.relative(f.path, from: root.path))
        .toList();
    expect(found, [p.join('Kept', 'Master.wav')]);
  });
}
