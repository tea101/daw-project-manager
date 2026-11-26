import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:daw_project_manager/services/preview_reference_repair.dart';
import '../helpers/test_factories.dart';

// Regression for v3.0.2: previews stored as macOS AppleDouble files
// ("._Tom2_19-02.wav") never play. The repair must fix only those references,
// and leave valid manual choices exactly as they are.
void main() {
  final dir = p.join('Volumes', 'DRIVE', 'Song', 'Mixdown');
  final real = p.join(dir, 'Tom2_19-02.wav');
  final ghost = p.join(dir, '._Tom2_19-02.wav');
  bool onlyReal(String path) => p.equals(path, real);
  bool nothing(String path) => false;

  group('PreviewReferenceRepair.repair', () {
    test('leaves a project with valid previews alone', () {
      final project = TestFactories.makeProject(
        previewSongPath: real,
        previewSongFileName: 'Tom2_19-02.wav',
        previewSongAutoPath: p.join(dir, 'Other.wav'),
        ignoredNewerSongPath: p.join(dir, 'Older.wav'),
      );
      expect(PreviewReferenceRepair.repair(project, fileExists: nothing), isNull);
    });

    test('leaves a missing (but genuine) manual preview alone', () {
      final project = TestFactories.makeProject(
        previewSongPath: p.join(dir, 'Gone.wav'),
        previewSongFileName: 'Gone.wav',
      );
      expect(PreviewReferenceRepair.repair(project, fileExists: nothing), isNull);
    });

    test('auto preview on an AppleDouble file moves to the real file', () {
      final project = TestFactories.makeProject(previewSongAutoPath: ghost);
      final fixed = PreviewReferenceRepair.repair(project, fileExists: onlyReal)!;
      expect(fixed.previewSongAutoPath, real);
      expect(fixed.previewSongPath, isNull);
    });

    test('auto preview on an AppleDouble file is cleared when no real file', () {
      final project = TestFactories.makeProject(previewSongAutoPath: ghost);
      final fixed = PreviewReferenceRepair.repair(project, fileExists: nothing)!;
      expect(fixed.previewSongAutoPath, isNull);
    });

    test('manual AppleDouble preview becomes the real file, still manual', () {
      final project = TestFactories.makeProject(
        previewSongPath: ghost,
        previewSongFileName: '._Tom2_19-02.wav',
      );
      final fixed = PreviewReferenceRepair.repair(project, fileExists: onlyReal)!;
      expect(fixed.previewSongPath, real);
      expect(fixed.previewSongFileName, 'Tom2_19-02.wav');
    });

    test('manual AppleDouble preview without a real file is cleared', () {
      final project = TestFactories.makeProject(
        previewSongPath: ghost,
        previewSongFileName: '._Tom2_19-02.wav',
        previewSongAutoPath: p.join(dir, 'Auto.wav'),
      );
      final fixed = PreviewReferenceRepair.repair(project, fileExists: nothing)!;
      expect(fixed.previewSongPath, isNull);
      expect(fixed.previewSongFileName, isNull);
      // The genuine auto preview is kept and now takes over.
      expect(fixed.previewSongAutoPath, p.join(dir, 'Auto.wav'));
    });

    test('a valid manual preview is kept while a bad auto one is fixed', () {
      final manual = p.join(dir, 'Chosen.wav');
      final project = TestFactories.makeProject(
        previewSongPath: manual,
        previewSongFileName: 'Chosen.wav',
        previewSongAutoPath: ghost,
      );
      final fixed = PreviewReferenceRepair.repair(project, fileExists: onlyReal)!;
      expect(fixed.previewSongPath, manual);
      expect(fixed.previewSongFileName, 'Chosen.wav');
      expect(fixed.previewSongAutoPath, real);
    });

    test('an AppleDouble "Keep Current" answer is forgotten', () {
      final project = TestFactories.makeProject(
        previewSongPath: real,
        previewSongFileName: 'Tom2_19-02.wav',
        ignoredNewerSongPath: ghost,
      );
      final fixed = PreviewReferenceRepair.repair(project, fileExists: onlyReal)!;
      expect(fixed.ignoredNewerSongPath, isNull);
      expect(fixed.previewSongPath, real);
    });

    test('repairing twice changes nothing more', () {
      final project = TestFactories.makeProject(previewSongAutoPath: ghost);
      final once = PreviewReferenceRepair.repair(project, fileExists: onlyReal)!;
      expect(PreviewReferenceRepair.repair(once, fileExists: onlyReal), isNull);
    });

    test('describe lists only what changes', () {
      final project = TestFactories.makeProject(previewSongAutoPath: ghost);
      final fixed = PreviewReferenceRepair.repair(project, fileExists: onlyReal)!;
      final text = PreviewReferenceRepair.describe(project, fixed);
      expect(text, contains('auto'));
      expect(text, isNot(contains('manual')));
    });
  });
}
