import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:daw_project_manager/ui/widgets/project_audio_section.dart';
import 'package:daw_project_manager/utils/audio_format_info.dart';

import '../helpers/test_factories.dart';

/// v3.0.6 — where a project's audio is looked for, and what the app's own
/// player may play without a downmix.
void main() {
  test('a session: its file, and the folder it is in', () {
    final project =
        TestFactories.makeProject(filePath: p.join('/lib', 'Song', 'Song.ptx'));
    final sources = audioSourcesFor(project);
    expect(sources.sessions, [p.join('/lib', 'Song', 'Song.ptx')]);
    expect(sources.folders, [p.join('/lib', 'Song')]);
  });

  test('a version stack is never searched as a folder of its own', () {
    final stack = TestFactories.makeProject(
        id: 'stack', filePath: p.join('/lib', 'Song'), isVirtual: true);
    final members = [
      TestFactories.makeProject(
          id: 'v1', filePath: p.join('/lib', 'Song', 'V1', 'Song V1.ptx')),
      TestFactories.makeProject(
          id: 'v2', filePath: p.join('/lib', 'Song', 'V2', 'Song V2.mon')),
    ];
    final sources = audioSourcesFor(stack, stackMembers: members);
    expect(sources.sessions, [members[0].filePath, members[1].filePath]);
    expect(sources.folders,
        [p.join('/lib', 'Song', 'V1'), p.join('/lib', 'Song', 'V2')]);
    expect(sources.folders, isNot(contains(stack.filePath)));
  });

  test('a standalone audio row has no session or folder to read', () {
    final row = TestFactories.makeProject(filePath: p.join('/lib', 'Master.wav'));
    final sources = audioSourcesFor(row);
    expect(sources.sessions, isEmpty);
    expect(sources.folders, isEmpty);
  });

  test('only up to two channels play in the app, never ADM', () {
    expect(playableInApp(null), isTrue, reason: 'MP3 and the like: no header read');
    expect(playableInApp(const AudioFormatInfo(container: AudioContainer.wav, channels: 2)),
        isTrue);
    expect(playableInApp(const AudioFormatInfo(container: AudioContainer.wav, channels: 6)),
        isFalse);
    expect(
        playableInApp(const AudioFormatInfo(
            container: AudioContainer.rf64, channels: 2, hasAxml: true)),
        isFalse);
  });
}
