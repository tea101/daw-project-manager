import 'package:daw_project_manager/repository/project_repository.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ProjectRepository.newProjectStatus', () {
    test('uses the first configured phase', () {
      expect(
        ProjectRepository.newProjectStatus(
            ['Pending Review', 'Mixing', 'Mastering', 'Quality Assurance', 'Finished']),
        'Pending Review',
      );
    });

    test('default phases still start at Idea', () {
      expect(
        ProjectRepository.newProjectStatus(
            ['Idea', 'Arranging', 'Mixing', 'Mastering', 'Finished']),
        'Idea',
      );
    });

    test('falls back to Idea when no phases are configured', () {
      expect(ProjectRepository.newProjectStatus(const []), 'Idea');
    });
  });
}
