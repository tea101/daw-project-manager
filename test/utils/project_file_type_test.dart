import 'package:flutter_test/flutter_test.dart';

import 'package:daw_project_manager/utils/project_file_type.dart';

import '../helpers/test_factories.dart';

/// v3.0.6 — the File Type column's labels come from the actual file, and a
/// version stack is never mistaken for a folder.
void main() {
  String label(String path) =>
      projectFileTypeLabel(TestFactories.makeProject(filePath: path));

  test('compact labels from the file', () {
    expect(label('/p/Song/Song Mix V5.ptx'), 'PTX');
    expect(label('/p/Song/Song Atmos Master.mon'), 'MON');
    expect(label('/p/Song/Song.wpr'), 'WPR');
    expect(label('/p/Song/Song.als'), 'ALS');
    expect(label('/p/Song Master.wav'), 'WAV');
    expect(label('/p/Song Master.WAV'), 'WAV');
    expect(label('/p/Song Master.aiff'), 'AIF');
    expect(label('/p/Song Master.aif'), 'AIF');
    expect(label('/p/Song.logicx'), 'LOGICX');
    expect(label('/p/Song.bwproject'), 'BWP');
    expect(label('/p/Song'), kFolderFileTypeLabel);
  });

  test('the name never decides: "Song.ptx Master.wav" is WAV', () {
    expect(label('/p/Song.ptx Master.wav'), 'WAV');
  });

  test('a version stack is STACK, not FOLDER', () {
    final stack =
        TestFactories.makeProject(filePath: '/p/Song', isVirtual: true);
    expect(projectFileTypeLabel(stack), kStackFileTypeLabel);
    expect(isStandaloneAudioProject(stack), isFalse);
  });

  test('standalone audio rows', () {
    expect(isStandaloneAudioProject(
        TestFactories.makeProject(filePath: '/p/Master.wav')), isTrue);
    expect(isStandaloneAudioProject(
        TestFactories.makeProject(filePath: '/p/Song.mon')), isFalse);
  });
}
