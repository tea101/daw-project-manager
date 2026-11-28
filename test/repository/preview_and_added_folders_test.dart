import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:daw_project_manager/repository/audio_index_store.dart';
import 'package:daw_project_manager/repository/project_repository.dart';

import '../helpers/hive_test_helper.dart';
import '../helpers/test_factories.dart';

/// v3.0.6 regressions found on a real library.
void main() {
  late Directory tempDir;
  late ProjectRepository repo;

  setUp(() async {
    tempDir = await HiveTestHelper.setUp();
    repo = await HiveTestHelper.createRepository();
  });
  tearDown(() async => HiveTestHelper.tearDown(tempDir));

  group('Use as preview', () {
    test('saves onto the project as stored now, never a stale copy', () async {
      // The audio page opened with this copy of the project…
      final opened = TestFactories.makeProject(
        id: 'p1',
        filePath: '/v/Song/Song.ptx',
        tags: const ['Current Version', 'Dolby Atmos Mastering'],
        status: 'Mixing',
      );
      await repo.projectsBox.put(opened.id, opened);
      // …then the project was edited elsewhere: a tag removed, the phase
      // changed.
      await repo.updateProject(repo.getById('p1')!.copyWith(
        tags: const ['Current Version'],
        status: 'Finished',
      ));

      expect(await repo.setPreviewSong('p1', '/v/Song/Bounces/Mix.wav'),
          isTrue);

      final saved = repo.getById('p1')!;
      expect(saved.previewSongPath, '/v/Song/Bounces/Mix.wav');
      expect(saved.previewSongFileName, 'Mix.wav');
      // The edits made since the page opened are kept.
      expect(saved.tags, ['Current Version']);
      expect(saved.status, 'Finished');
    });

    test('a project deleted meanwhile is not brought back', () async {
      expect(await repo.setPreviewSong('gone', '/v/x.wav'), isFalse);
      expect(repo.getById('gone'), isNull);
    });
  });

  group('Automatic previews from the audio index', () {
    test('set only when the project has no preview at all', () async {
      await repo.projectsBox.put('none', TestFactories.makeProject(
          id: 'none', filePath: '/v/A/A.ptx'));
      await repo.projectsBox.put('manual', TestFactories.makeProject(
          id: 'manual',
          filePath: '/v/B/B.ptx',
          previewSongPath: '/v/B/Mine.wav',
          previewSongFileName: 'Mine.wav'));
      await repo.projectsBox.put('auto', TestFactories.makeProject(
          id: 'auto',
          filePath: '/v/C/C.ptx',
          previewSongAutoPath: '/v/C/Bounces/C.wav'));

      expect(await repo.setAutoPreviewIfNone('none', '/v/A/A Master.wav'),
          isTrue);
      expect(repo.getById('none')!.previewSongAutoPath, '/v/A/A Master.wav');
      expect(repo.getById('none')!.previewSongPath, isNull);

      // The user's choice is never overwritten, nor an automatic one.
      expect(await repo.setAutoPreviewIfNone('manual', '/v/B/B Master.wav'),
          isFalse);
      expect(repo.getById('manual')!.previewSongPath, '/v/B/Mine.wav');
      expect(repo.getById('manual')!.previewSongAutoPath, isNull);
      expect(await repo.setAutoPreviewIfNone('auto', '/v/C/C Master.wav'),
          isFalse);
      expect(repo.getById('auto')!.previewSongAutoPath, '/v/C/Bounces/C.wav');
    });

    test('sessions are counted per folder; stacks do not count', () async {
      await repo.projectsBox.put('1', TestFactories.makeProject(
          id: '1', filePath: '/v/Miles/Track 6.ptx'));
      await repo.projectsBox.put('2', TestFactories.makeProject(
          id: '2', filePath: '/v/Miles/Track 7.ptx'));
      await repo.projectsBox.put('3', TestFactories.makeProject(
          id: '3', filePath: '/v/Solo/Solo.ptx'));
      await repo.projectsBox.put('s', TestFactories.makeProject(
          id: 's', filePath: '/v/Solo/Stack', isVirtual: true));
      final counts = repo.sessionsPerFolder();
      expect(counts[ProjectRepository.sessionFolderKey('/v/Miles/Track 6.ptx')],
          2);
      expect(counts[ProjectRepository.sessionFolderKey('/v/Solo/Solo.ptx')],
          1);
    });
  });

  group('Added audio folders (device-local store)', () {
    test('kept per project, in order, each once', () async {
      final store = AudioIndexStore(repo.profileId);
      expect(await store.addedFolders('p1'), isEmpty);
      await store.setAddedFolders('p1', ['/v/A', '/v/B', '/v/A', '']);
      expect(await store.addedFolders('p1'), ['/v/A', '/v/B']);
      expect(await store.addedFolders('p2'), isEmpty);
      expect(await store.allAddedFolders(), {
        'p1': ['/v/A', '/v/B'],
      });
    });

    test('an empty list removes the entry', () async {
      final store = AudioIndexStore(repo.profileId);
      await store.setAddedFolders('p1', ['/v/A']);
      await store.setAddedFolders('p1', const []);
      expect(await store.allAddedFolders(), isEmpty);
    });

    test('pruning the index never drops the user\'s added folders', () async {
      final store = AudioIndexStore(repo.profileId);
      await store.setAddedFolders('p1', ['/v/A']);
      await store.retainOnly({'someone-else'});
      expect(await store.addedFolders('p1'), ['/v/A']);
    });
  });
}
