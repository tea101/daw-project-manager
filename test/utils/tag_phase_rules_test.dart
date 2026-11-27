import 'package:flutter_test/flutter_test.dart';

import 'package:daw_project_manager/models/tag_definition.dart';
import 'package:daw_project_manager/services/tag_library_merge.dart';
import 'package:daw_project_manager/utils/project_tags.dart';
import 'package:daw_project_manager/utils/tag_phase_rules.dart';

import '../helpers/test_factories.dart';

/// Tag-to-phase rules (v3.0.4): only Previous Version offers a phase by
/// default, Approved Master never does, conflicts are asked, and nothing
/// moves without confirmation (the UI asks whatever these return).
void main() {
  const phases = [
    'Pending Review', 'Mixing', 'Mastering', 'Quality Assurance', 'Finished',
    'Previous Version',
  ];
  final library = kDefaultTagLibrary;

  test('Previous Version offers the Previous Version phase, with the count', () {
    final projects = [
      TestFactories.makeProject(id: 'a', status: 'Mixing'),
      TestFactories.makeProject(id: 'b', status: 'Finished'),
      TestFactories.makeProject(id: 'c', status: 'Previous Version'),
    ];
    final q = planTagPhaseQuestion(
      projects: projects,
      addedTags: ['previous version'],
      library: library,
      phases: phases,
    );
    expect(q, isA<ConfirmPhaseChange>());
    final c = q as ConfirmPhaseChange;
    expect(c.phase, 'Previous Version');
    expect(c.affected.map((p) => p.id), ['a', 'b']);
  });

  test('Approved Master keeps the phase — never Finished', () {
    final q = planTagPhaseQuestion(
      projects: [TestFactories.makeProject(status: 'Quality Assurance')],
      addedTags: ['Approved Master'],
      library: library,
      phases: phases,
    );
    expect(q, isA<NoPhaseQuestion>());
  });

  test('any other tag keeps the phase', () {
    final q = planTagPhaseQuestion(
      projects: [TestFactories.makeProject(status: 'Mixing')],
      addedTags: ['Vocals', 'Remix'],
      library: library,
      phases: phases,
    );
    expect(q, isA<NoPhaseQuestion>());
  });

  test('a rule naming a phase the profile lacks does nothing', () {
    final q = planTagPhaseQuestion(
      projects: [TestFactories.makeProject(status: 'Mixing')],
      addedTags: ['Previous Version'],
      library: library,
      phases: phases.where((p) => p != 'Previous Version').toList(),
    );
    expect(q, isA<NoPhaseQuestion>());
    expect(
      ruleNeedsMissingPhase(library, ['Finished'], kPreviousVersionPhase),
      isTrue,
    );
    expect(ruleNeedsMissingPhase(library, phases, kPreviousVersionPhase), isFalse);
  });

  test('every project already there: nothing to ask', () {
    final q = planTagPhaseQuestion(
      projects: [TestFactories.makeProject(status: 'Previous Version')],
      addedTags: ['Previous Version'],
      library: library,
      phases: phases,
    );
    expect(q, isA<NoPhaseQuestion>());
  });

  test('conflicting rules ask which phase', () {
    final custom = [
      ...library,
      const TagDefinition(id: 'x', name: 'Needs Remaster', phase: 'Mastering', order: 5),
    ];
    final q = planTagPhaseQuestion(
      projects: [TestFactories.makeProject(status: 'Mixing')],
      addedTags: ['Needs Remaster', 'Previous Version'],
      library: custom,
      phases: phases,
    );
    expect(q, isA<ChoosePhase>());
    expect((q as ChoosePhase).phases, ['Mastering', 'Previous Version']);
    expect(projectsToMove([TestFactories.makeProject(status: 'Mastering')], 'Mastering'),
        isEmpty);
  });

  test('two tags with the same rule are no conflict', () {
    final custom = [
      ...library,
      const TagDefinition(id: 'y', name: 'Old Take', phase: 'Previous Version', order: 6),
    ];
    final q = planTagPhaseQuestion(
      projects: [TestFactories.makeProject(status: 'Mixing')],
      addedTags: ['Old Take', 'Previous Version'],
      library: custom,
      phases: phases,
    );
    expect(q, isA<ConfirmPhaseChange>());
  });

  test('a deleted library tag has no rule any more', () {
    final deleted = [
      for (final t in library)
        t.name == 'Previous Version' ? t.copyWith(deletedAt: DateTime(2026)) : t,
    ];
    final q = planTagPhaseQuestion(
      projects: [TestFactories.makeProject(status: 'Mixing')],
      addedTags: ['Previous Version'],
      library: deleted,
      phases: phases,
    );
    expect(q, isA<NoPhaseQuestion>());
  });

  group('renameTag', () {
    test('renames in place, ignoring case', () {
      expect(renameTag(['a', 'Old', 'b'], 'old', 'New'), ['a', 'New', 'b']);
    });
    test('no-op returns the same list', () {
      final tags = ['a'];
      expect(identical(renameTag(tags, 'x', 'y'), tags), isTrue);
    });
    test('never leaves the new name twice', () {
      expect(renameTag(['Old', 'New'], 'Old', 'New'), ['New']);
      expect(renameTag(['New', 'Old'], 'Old', 'New'), ['New']);
    });
  });
}
