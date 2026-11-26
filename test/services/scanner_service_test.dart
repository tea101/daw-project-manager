import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:daw_project_manager/services/scanner_service.dart';

void main() {
  group('bundle directory detection', () {
    // Regression coverage: LUNA (.luna) and GarageBand (.band) save projects
    // as a directory bundle, same as Logic Pro's .logicx — but scanDirectory
    // used to only special-case .logicx, so a .luna/.band bundle would get
    // pushed onto the traversal stack and recursed into instead of yielded
    // as a single project, silently finding nothing (no supported extension
    // lives inside the bundle's own contents).
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('scanner_bundle_test_');
    });

    tearDown(() async {
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    });

    test('.luna bundle directory is yielded as a single project', () async {
      final lunaDir = Directory(p.join(tempDir.path, 'My Song.luna'));
      await lunaDir.create(recursive: true);
      await File(p.join(lunaDir.path, 'session.dat')).writeAsString('fake');

      final results = await ScannerService().scanDirectory(tempDir.path).toList();

      expect(results, hasLength(1));
      expect(results.first.path, lunaDir.path);
      expect(results.first, isA<Directory>());
    });

    test('.band bundle directory (GarageBand) is yielded as a single project', () async {
      final bandDir = Directory(p.join(tempDir.path, 'My Song.band'));
      await bandDir.create(recursive: true);
      await File(p.join(bandDir.path, 'projectData')).writeAsString('fake');

      final results = await ScannerService().scanDirectory(tempDir.path).toList();

      expect(results, hasLength(1));
      expect(results.first.path, bandDir.path);
    });
  });

  group('WaveLab project files', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('scanner_wavelab_test_');
    });

    tearDown(() async {
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    });

    test('.mon and .wpr are supported extensions', () {
      expect(ScannerService.supportedExtensions, contains('.mon'));
      expect(ScannerService.supportedExtensions, contains('.wpr'));
    });

    test('a scan finds WaveLab montages and projects', () async {
      final mon = File(p.join(tempDir.path, 'Master', 'Album.mon'));
      final wpr = File(p.join(tempDir.path, 'Master', 'Album.wpr'));
      await mon.create(recursive: true);
      await wpr.create(recursive: true);
      await File(p.join(tempDir.path, 'Master', 'Track 1.wav')).writeAsString('x');

      final results = await ScannerService().scanDirectory(tempDir.path).toList();
      final paths = results.map((e) => e.path).toSet();

      expect(paths, {mon.path, wpr.path});
    });

    test('a WaveLab project reveals its containing folder', () async {
      final mon = File(p.join(tempDir.path, 'Album.mon'));
      await mon.writeAsString('x');
      expect(ScannerService.projectContainingFolder(mon.path), tempDir.path);
    });
  });

  group('scan exclusions: WaveLab Backup.mon and macOS AppleDouble files', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('scanner_exclusion_test_');
    });

    tearDown(() async {
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    });

    Future<File> touch(List<String> parts, {DateTime? modified}) async {
      final f = File(p.joinAll([tempDir.path, ...parts]));
      await f.create(recursive: true);
      await f.writeAsString('x');
      if (modified != null) await f.setLastModified(modified);
      return f;
    }

    Future<Set<String>> scanned() async =>
        (await ScannerService().scanDirectory(tempDir.path).toList())
            .map((e) => e.path)
            .toSet();

    test('montages in Backup.mon are skipped; the montage beside it is found', () async {
      final montage = await touch(['Album', 'Album.mon']);
      final project = await touch(['Album', 'Album.wpr']);
      await touch(['Album', 'Backup.mon', 'Album_#1.mon']);
      await touch(['Album', 'Backup.mon', 'Album_#2.mon']);

      expect(await scanned(), {montage.path, project.path});
    });

    test('Backup.mon is matched whatever its letter case', () async {
      final montage = await touch(['Album', 'Album.mon']);
      await touch(['Album', 'BACKUP.MON', 'Album_#1.mon']);

      expect(await scanned(), {montage.path});
    });

    test('a montage named with "_#" outside Backup.mon is still found', () async {
      final named = await touch(['Album', 'Mix_#2.mon']);
      expect(await scanned(), {named.path});
    });

    test('AppleDouble files are skipped for every DAW', () async {
      final real = <String>{};
      for (final name in ['Song.ptx', 'Song.als', 'Song.cpr', 'Song.flp', 'Song.rpp', 'Song.mon', 'Song.wpr']) {
        real.add((await touch([name.split('.').last, name])).path);
        await touch([name.split('.').last, '._$name']);
      }
      expect(await scanned(), real);
    });

    test("a bundle's AppleDouble file is skipped, the bundle is found", () async {
      final bundle = Directory(p.join(tempDir.path, 'Song.logicx'));
      await bundle.create(recursive: true);
      await File(p.join(bundle.path, 'projectData')).writeAsString('x');
      await touch(['._Song.logicx']);

      expect(await scanned(), {bundle.path});
    });

    test('smart-folder scan never picks a newer AppleDouble file over the project', () async {
      final now = DateTime.now();
      final real = await touch(['Song', 'Session.ptx'], modified: now.subtract(const Duration(days: 1)));
      await touch(['Song', '._Session.ptx'], modified: now);

      final results = await ScannerService().scanDirectoryShallow(tempDir.path).toList();
      expect(results.map((r) => r.file.path), [real.path]);
    });

    test('smart-folder scan finds nothing in a Backup.mon folder', () async {
      await touch(['Backup.mon', 'Album_#1.mon']);
      final results = await ScannerService().scanDirectoryShallow(tempDir.path).toList();
      expect(results, isEmpty);
    });

    test('path rules', () {
      expect(ScannerService.isAppleDoublePath(p.join('a', '._Song.ptx')), isTrue);
      expect(ScannerService.isAppleDoublePath(p.join('._folder', 'Song.ptx')), isFalse);
      expect(ScannerService.isAppleDoublePath(p.join('a', 'My._Song.ptx')), isFalse);
      expect(ScannerService.isWaveLabBackupPath(p.join('a', 'Backup.mon', 'x_#1.mon')), isTrue);
      expect(ScannerService.isWaveLabBackupPath(p.join('a', 'Backup', 'x.mon')), isFalse);
      expect(ScannerService.isNewlyExcludedPath(p.join('a', 'Album.mon')), isFalse);
    });
  });

  group('projectContainingFolder', () {
    // Regression coverage for GitHub issue #142: "Open Folder" on a Logic Pro
    // / LUNA project opened the project in the DAW instead of revealing its
    // folder. Cause: the project's stored path IS the `.logicx`/`.luna`
    // directory (a package bundle), and the old logic did "if it's a
    // directory, open it as-is" — but `open`ing a bundle on macOS launches
    // the DAW. A bundle must resolve to its *parent*, same as a single file.
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('containing_folder_test_');
    });
    tearDown(() async {
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    });

    test('a .logicx bundle resolves to its parent folder, not itself', () async {
      final logicx = Directory(p.join(tempDir.path, 'Song.logicx'));
      await logicx.create();
      expect(
        ScannerService.projectContainingFolder(logicx.path),
        tempDir.path,
      );
    });

    test('a .luna bundle resolves to its parent folder', () async {
      final luna = Directory(p.join(tempDir.path, 'Song.luna'));
      await luna.create();
      expect(ScannerService.projectContainingFolder(luna.path), tempDir.path);
    });

    test('a single-file project resolves to its parent folder', () async {
      final flp = File(p.join(tempDir.path, 'Song.flp'));
      await flp.writeAsString('x');
      expect(ScannerService.projectContainingFolder(flp.path), tempDir.path);
    });

    test('a genuine loose-files project folder resolves to itself', () async {
      final projectDir = Directory(p.join(tempDir.path, 'My Project'));
      await projectDir.create();
      expect(
        ScannerService.projectContainingFolder(projectDir.path),
        projectDir.path,
      );
    });

    test(
      'release-detail "Open Folder" reveals the containing folder of a bundle '
      'track, not the bundle (release_detail_page had its own un-fixed copy of '
      'the #142 inline logic)',
      () async {
        // The releases tab track tile used to compute its folder as
        // `isDirectorySync(path) ? path : dirname(path)` — the exact naive
        // expression #142 removed from the dashboard. For a Logic Pro track
        // that meant opening the `.logicx` bundle, launching Logic instead of
        // showing the folder. It must now route through this helper like every
        // other "Open Folder" entry point.
        final songFolder = Directory(p.join(tempDir.path, 'Release', 'Track 01'));
        await songFolder.create(recursive: true);
        final logicx = Directory(p.join(songFolder.path, 'Track 01.logicx'));
        await logicx.create();

        expect(
          ScannerService.projectContainingFolder(logicx.path),
          songFolder.path,
        );
      },
    );

    test('isBundlePath is case-insensitive and extension-anchored', () {
      expect(ScannerService.isBundlePath('/x/Song.logicx'), isTrue);
      expect(ScannerService.isBundlePath('/x/Song.LOGICX'), isTrue);
      expect(ScannerService.isBundlePath('/x/Song.luna'), isTrue);
      expect(ScannerService.isBundlePath('/x/Song.band'), isTrue);
      expect(ScannerService.isBundlePath('/x/Song.als'), isFalse);
      expect(ScannerService.isBundlePath('/x/logicx-notes.txt'), isFalse);
    });
  });

  group('newlyFoundPaths', () {
    // Regression coverage for the "New" badge (recentlyDiscoveredProjectsProvider)
    // now that both the initial scan and a manual rescan run without blocking
    // the UI: a project that appears mid-scan needs to be distinguishable
    // from one that was already known, purely by comparing scan output
    // against a pre-scan snapshot of known paths.

    test('returns paths not present in knownPaths', () {
      final found = {'/a/one.als', '/a/two.als', '/a/three.als'};
      final known = {'/a/one.als'};

      expect(newlyFoundPaths(found, known), {'/a/two.als', '/a/three.als'});
    });

    test('returns empty when every found path was already known', () {
      final found = {'/a/one.als', '/a/two.als'};
      final known = {'/a/one.als', '/a/two.als', '/a/other.als'};

      expect(newlyFoundPaths(found, known), isEmpty);
    });

    test('returns everything found when nothing was previously known', () {
      final found = {'/a/one.als', '/a/two.als'};

      expect(newlyFoundPaths(found, {}), found);
    });

    test('is empty when the scan found nothing', () {
      expect(newlyFoundPaths({}, {'/a/one.als'}), isEmpty);
    });
  });
}
