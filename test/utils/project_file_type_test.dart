import 'package:flutter_test/flutter_test.dart';

import 'package:daw_project_manager/utils/project_file_type.dart';

import '../helpers/test_factories.dart';

/// v3.0.6 — the File Type column's labels come from the actual file, and a
/// version stack is never mistaken for a folder.
void main() {
  String label(String path) =>
      projectFileTypeLabel(TestFactories.makeProject(filePath: path));

  test('compact labels from the file', () {
    expect(label('/p/Song/Song Mix V5.ptx'), 'ptx');
    expect(label('/p/Song/Song Atmos Master.mon'), 'mon');
    expect(label('/p/Song/Song.wpr'), 'wpr');
    expect(label('/p/Song/Song.als'), 'als');
    expect(label('/p/Song Master.wav'), 'wav');
    expect(label('/p/Song Master.WAV'), 'wav');
    expect(label('/p/Song Master.aiff'), 'aif');
    expect(label('/p/Song Master.aif'), 'aif');
    expect(label('/p/Song.logicx'), 'logicx');
    expect(label('/p/Song.bwproject'), 'bwp');
    expect(label('/p/Song'), kFolderFileTypeLabel);
  });

  test('labels are lowercase, as extensions are written (display only)', () {
    expect(label('/p/Song/SONG.PTX'), 'ptx');
    expect(label('/p/Song Master.BWF'), 'wav');
    expect(kStackFileTypeLabel, 'stack');
    expect(kFolderFileTypeLabel, 'folder');
  });

  test('the name never decides: "Song.ptx Master.wav" is wav', () {
    expect(label('/p/Song.ptx Master.wav'), 'wav');
  });

  test('a version stack is "stack", not "folder"', () {
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
