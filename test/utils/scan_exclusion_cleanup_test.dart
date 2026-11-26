import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:daw_project_manager/utils/scan_exclusion_cleanup.dart';

import '../helpers/test_factories.dart';

void main() {
  final root = p.join(p.separator, 'Volumes', 'PROJECT DRIVE', 'Album');

  group('findScanExclusionCleanup', () {
    test('offers WaveLab Backup.mon copies and AppleDouble files, nothing else', () {
      final genuineMontage = TestFactories.makeProject(
        id: 'montage',
        filePath: p.join(root, 'Album.mon'),
        notes: 'keep my notes',
      );
      final genuineProject = TestFactories.makeProject(
        id: 'wpr',
        filePath: p.join(root, 'Album.wpr'),
      );
      final backup = TestFactories.makeProject(
        id: 'backup',
        filePath: p.join(root, 'Backup.mon', 'Album_#3.mon'),
      );
      final appleDoublePt = TestFactories.makeProject(
        id: 'ad-pt',
        filePath: p.join(root, 'Song', '._Song.ptx'),
      );
      final appleDoubleLogic = TestFactories.makeProject(
        id: 'ad-logic',
        filePath: p.join(root, '._Song.logicx'),
      );
      final genuinePt = TestFactories.makeProject(
        id: 'pt',
        filePath: p.join(root, 'Song', 'Song.ptx'),
      );

      final result = findScanExclusionCleanup(
        [genuineMontage, genuineProject, backup, appleDoublePt, appleDoubleLogic, genuinePt],
        const {},
      );

      expect(result.removable.map((e) => e.id).toSet(), {'backup', 'ad-pt', 'ad-logic'});
      expect(result.keptForReleases, isEmpty);
    });

    test('WaveLab 13 system.mon backups are offered; the montage beside them is not', () {
      final montage = TestFactories.makeProject(
        id: 'montage13',
        filePath: p.join(root, 'WAVELAB', 'Soul Witness.wav.mon'),
        notes: 'genuine',
      );
      final backup = TestFactories.makeProject(
        id: 'backup13',
        filePath: p.join(root, 'WAVELAB', 'system.mon', 'backups', 'Soul Witness.wav_#_16.mon'),
      );
      final result = findScanExclusionCleanup([montage, backup], const {});
      expect(result.removable.map((e) => e.id), ['backup13']);
    });

    test('a montage merely named with "_#" outside Backup.mon is a real project', () {
      final named = TestFactories.makeProject(
        id: 'named',
        filePath: p.join(root, 'Mix_#2.mon'),
      );
      expect(findScanExclusionCleanup([named], const {}).isEmpty, isTrue);
    });

    test('Backup.mon matches whatever its letter case', () {
      final upper = TestFactories.makeProject(
        id: 'upper',
        filePath: p.join(root, 'BACKUP.MON', 'Album_#1.mon'),
      );
      expect(findScanExclusionCleanup([upper], const {}).removable, hasLength(1));
    });

    test('an entry on a release is reported, never offered', () {
      final onRelease = TestFactories.makeProject(
        id: 'on-release',
        filePath: p.join(root, '._Single.ptx'),
      );
      final result = findScanExclusionCleanup([onRelease], {'on-release'});
      expect(result.removable, isEmpty);
      expect(result.keptForReleases.single.id, 'on-release');
    });

    test('version stacks and archived projects are never offered', () {
      final stack = TestFactories.makeProject(
        id: 'stack',
        filePath: p.join(root, 'Backup.mon'),
        isVirtual: true,
        memberProjectIds: const ['a', 'b'],
      );
      final archived = TestFactories.makeProject(
        id: 'archived',
        filePath: p.join(root, '._Old.ptx'),
        archivePath: p.join(p.separator, 'Archive', 'Old.zip'),
      );
      expect(findScanExclusionCleanup([stack, archived], const {}).isEmpty, isTrue);
    });
  });
}
