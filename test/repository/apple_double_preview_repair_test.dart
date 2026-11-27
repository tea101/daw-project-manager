import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:daw_project_manager/repository/project_repository.dart';

import '../helpers/hive_test_helper.dart';
import '../helpers/test_factories.dart';

/// Regression for v3.0.2: preview references stored as macOS AppleDouble
/// files are repaired in the catalogue — and only those, and never on disk.
void main() {
  late Directory tempDir;
  late ProjectRepository repo;

  setUp(() async {
    tempDir = await HiveTestHelper.setUp();
    repo = await HiveTestHelper.createRepository();
  });

  tearDown(() async {
    await HiveTestHelper.tearDown(tempDir);
  });

  test('repairs AppleDouble previews, keeps valid ones, touches no file', () async {
    final mix = Directory(p.join(tempDir.path, 'Song', 'Mixdown'))
      ..createSync(recursive: true);
    final real = File(p.join(mix.path, 'Tom2_19-02.wav'))..writeAsBytesSync([1, 2]);
    final ghost = File(p.join(mix.path, '._Tom2_19-02.wav'))..writeAsBytesSync([9]);
    final chosen = File(p.join(mix.path, 'Chosen.wav'))..writeAsBytesSync([3]);

    await repo.projectsBox.put(
      'bad',
      TestFactories.makeProject(id: 'bad', previewSongAutoPath: ghost.path),
    );
    await repo.projectsBox.put(
      'good',
      TestFactories.makeProject(
        id: 'good',
        previewSongPath: chosen.path,
        previewSongFileName: 'Chosen.wav',
      ),
    );

    final planned = <String>[];
    final dry = await repo.repairPreviewReferences(
      dryRun: true,
      onPlanned: (before, after) => planned.add(before.id),
    );
    expect(dry, 1);
    expect(planned, ['bad']);
    expect(repo.projectsBox.get('bad')!.previewSongAutoPath, ghost.path,
        reason: 'a dry run saves nothing');

    expect(await repo.repairPreviewReferences(), 1);
    // Cleared, for detection to run again — never repointed.
    expect(repo.projectsBox.get('bad')!.previewSongAutoPath, isNull);
    expect(repo.projectsBox.get('good')!.previewSongPath, chosen.path);

    // Nothing on disk changed.
    expect(ghost.existsSync(), isTrue);
    expect(ghost.readAsBytesSync(), [9]);
    expect(real.readAsBytesSync(), [1, 2]);

    // A second pass has nothing to do.
    expect(await repo.repairPreviewReferences(), 0);
  });
}
