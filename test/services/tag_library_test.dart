import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:daw_project_manager/models/tag_definition.dart';
import 'package:daw_project_manager/services/backup_service.dart';
import 'package:daw_project_manager/services/tag_library_merge.dart';

import '../helpers/hive_test_helper.dart';

/// The tag library (v3.0.4): defaults, storage, merge, the pickers' list and
/// the Previous Version phase placement.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  TagDefinition tag(String id, String name,
          {String? phase, int order = 0, DateTime? updatedAt, DateTime? deletedAt}) =>
      TagDefinition(
        id: id,
        name: name,
        phase: phase,
        order: order,
        updatedAt: updatedAt,
        deletedAt: deletedAt,
      );

  group('defaults', () {
    test('a library never written reads as Previous Version + Approved Master', () {
      final lib = decodeTagLibrary(null);
      expect(lib.map((t) => t.name), ['Previous Version', 'Approved Master']);
      expect(lib.first.phase, kPreviousVersionPhase);
      // Approved Master keeps the phase: Finished stays a manual decision.
      expect(lib.last.phase, isNull);
    });

    test('a stored list, even empty, is the user\'s', () {
      expect(decodeTagLibrary('[]'), isEmpty);
    });

    test('garbage falls back to the defaults, never throws', () {
      expect(decodeTagLibrary('{nope'), kDefaultTagLibrary);
    });

    test('round-trips through JSON', () {
      final t = tag('a', 'Mixed', phase: 'Mixing', updatedAt: DateTime(2026, 3, 1))
          .copyWith(colorHex: '#FF0000');
      expect(decodeTagLibrary(encodeTagLibrary([t])).single, t);
    });
  });

  group('mergeTagLibraries', () {
    test('union: absence is never a deletion', () {
      final merged = mergeTagLibraries(
        [tag('a', 'A', updatedAt: DateTime(2026))],
        [tag('b', 'B', updatedAt: DateTime(2026))],
      );
      expect(merged.map((t) => t.id), containsAll(['a', 'b']));
    });

    test('newer edit wins; an untimestamped default never displaces an edit', () {
      final edited = tag('default-previous-version', 'Older Version',
          phase: kPreviousVersionPhase, updatedAt: DateTime(2026, 5));
      expect(
        mergeTagLibraries([edited], kDefaultTagLibrary)
            .firstWhere((t) => t.id == edited.id)
            .name,
        'Older Version',
      );
      expect(
        mergeTagLibraries(kDefaultTagLibrary, [edited])
            .firstWhere((t) => t.id == edited.id)
            .name,
        'Older Version',
      );
    });

    test('a deletion travels as a tombstone and wins over an older copy', () {
      final live = tag('a', 'A', updatedAt: DateTime(2026, 1));
      final gone = tag('a', 'A', updatedAt: DateTime(2026, 2), deletedAt: DateTime(2026, 2));
      final merged = mergeTagLibraries([live], [gone]);
      expect(activeTagLibrary(merged), isEmpty);
    });
  });

  group('activeTagLibrary / tagChoices', () {
    test('hides tombstones, keeps order, shows a duplicated name once', () {
      final active = activeTagLibrary([
        tag('b', 'Mixed', order: 1),
        tag('a', 'Rough', order: 0),
        tag('c', 'mixed', order: 2),
        tag('d', 'Gone', order: 3, deletedAt: DateTime(2026)),
      ]);
      expect(active.map((t) => t.name), ['Rough', 'Mixed']);
    });

    test('library first (its spelling wins), then tags in use it lacks', () {
      final choices = tagChoices(
        [tag('a', 'Approved Master', order: 0), tag('b', 'Previous Version', order: 1)],
        ['zz Live', 'approved master', 'Acoustic'],
      );
      expect(choices, ['Approved Master', 'Previous Version', 'Acoustic', 'zz Live']);
    });

    test('tagDefinitionFor ignores case', () {
      expect(
        tagDefinitionFor(kDefaultTagLibrary, 'previous version')?.phase,
        kPreviousVersionPhase,
      );
      expect(tagDefinitionFor(kDefaultTagLibrary, 'Unknown'), isNull);
    });
  });

  group('withPreviousVersionPhase', () {
    test('goes right after Finished', () {
      expect(
        withPreviousVersionPhase(
            ['Pending Review', 'Mixing', 'Mastering', 'Quality Assurance', 'Finished']),
        ['Pending Review', 'Mixing', 'Mastering', 'Quality Assurance', 'Finished',
         'Previous Version'],
      );
      expect(withPreviousVersionPhase(['Idea', 'Finished', 'Archive']),
          ['Idea', 'Finished', 'Previous Version', 'Archive']);
    });

    test('at the end without Finished; unchanged when already there', () {
      expect(withPreviousVersionPhase(['A']), ['A', 'Previous Version']);
      final phases = ['A', 'Previous Version'];
      expect(identical(withPreviousVersionPhase(phases), phases), isTrue);
    });
  });

  group('local backup', () {
    late Directory tempDir;
    setUp(() async => tempDir = await HiveTestHelper.setUp());
    tearDown(() async => HiveTestHelper.tearDown(tempDir));

    test('a never-edited library backs up as the defaults', () async {
      expect((await BackupService.readTagLibraryForTest()).map((t) => t.id),
          kDefaultTagLibrary.map((t) => t.id));
    });

    test('restoring merges, keeping tags made since the backup', () async {
      await BackupService.writeTagLibraryForTest(
          [tag('here', 'Made here', updatedAt: DateTime(2026, 6))]);
      await BackupService.writeTagLibraryForTest(
          [tag('backup', 'From backup', updatedAt: DateTime(2026, 1))]);
      final names = activeTagLibrary(await BackupService.readTagLibraryForTest())
          .map((t) => t.name);
      expect(names, containsAll(['Made here', 'From backup']));
    });
  });
}
