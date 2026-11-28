import '../../models/music_project.dart';
import '../../utils/project_file_type.dart';
import '../scanner_service.dart';

/// One project for the audio index to read: its sessions and folders.
class AudioIndexJob {
  const AudioIndexJob({
    required this.projectId,
    required this.name,
    required this.sessions,
    required this.folders,
    this.addedFolders = const [],
  });

  final String projectId;
  final String name;
  final List<String> sessions;
  final List<String> folders;

  /// Folders the user added to this project's search.
  final List<String> addedFolders;
}

/// The sessions and folders to look in for [project]'s audio.
///
/// A version stack is a group the app keeps, not a folder on disk: its
/// versions' sessions are read and *their* folders searched — never the
/// stack's own path as if it were a folder of its own. A standalone audio
/// row has neither.
({List<String> sessions, List<String> folders}) audioSourcesFor(
  MusicProject project, {
  List<MusicProject> stackMembers = const [],
}) {
  if (isStandaloneAudioProject(project)) {
    return (sessions: const [], folders: const []);
  }
  if (project.isVirtual) {
    final sessions = [
      for (final m in stackMembers)
        if (!m.isArchived) m.filePath,
    ];
    final folders = {
      for (final s in sessions) ScannerService.projectContainingFolder(s),
    }.toList();
    return (sessions: sessions, folders: folders);
  }
  return (
    sessions: [project.filePath],
    folders: [ScannerService.projectContainingFolder(project.filePath)],
  );
}

/// What a full pass of the audio index reads: every project the list shows
/// ([library] — stacks rather than their versions), except archived ones
/// (their files are in a zip) and standalone audio rows (they are their own
/// audio). [all] supplies a stack's versions.
List<AudioIndexJob> audioIndexJobs(
  List<MusicProject> library,
  List<MusicProject> all, {
  Map<String, List<String>> addedFolders = const {},
}) {
  final members = <String, List<MusicProject>>{};
  for (final p in all) {
    final stack = p.stackId;
    if (stack != null) (members[stack] ??= []).add(p);
  }
  return [
    for (final project in library)
      if (!project.isArchived && !isStandaloneAudioProject(project))
        if (audioSourcesFor(project, stackMembers: members[project.id] ?? const [])
            case final sources when sources.sessions.isNotEmpty)
          AudioIndexJob(
            projectId: project.id,
            name: project.displayName,
            sessions: sources.sessions,
            folders: sources.folders,
            addedFolders: addedFolders[project.id] ?? const [],
          ),
  ];
}
