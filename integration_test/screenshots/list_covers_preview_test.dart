// Preview pictures of the projects list with cover art (v3.0.5): the real
// app on a demo library — never a real one — with generated covers on some
// projects and a long name or two, so the list's thumbnails, alignment and
// "…" can be judged before anything is installed.
//
//   flutter test integration_test/screenshots/list_covers_preview_test.dart -d linux \
//     --dart-define=DPM_DATA_DIR=daw_project_manager_screenshots \
//     --dart-define=DPM_HIDE_VERSION=true --dart-define=DPM_SCREENSHOTS=true
//
// Writes build/preview_screenshots/*.png. A tool, not part of CI's suite.

import 'dart:io';
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;

import 'package:daw_project_manager/main.dart' as app;
import 'package:daw_project_manager/models/music_project.dart';
import 'package:daw_project_manager/repository/profile_repository.dart';
import 'package:daw_project_manager/repository/project_repository.dart';
import 'package:daw_project_manager/services/demo_data_service.dart';
import 'package:daw_project_manager/utils/app_paths.dart';

const _size = Size(1920, 1080);

/// A square cover: a two-colour gradient with a big letter, written as PNG.
Future<String> _cover(String dir, String name, Color a, Color b, String letter) async {
  const side = 600.0;
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  final rect = const Offset(0, 0) & const Size(side, side);
  canvas.drawRect(
    rect,
    Paint()..shader = ui.Gradient.linear(rect.topLeft, rect.bottomRight, [a, b]),
  );
  canvas.drawCircle(const Offset(side * .7, side * .3), side * .22,
      Paint()..color = Colors.white.withValues(alpha: .25));
  final tp = TextPainter(
    text: TextSpan(
      text: letter,
      style: const TextStyle(fontSize: 300, fontWeight: FontWeight.w800, color: Colors.white),
    ),
    textDirection: TextDirection.ltr,
  )..layout();
  tp.paint(canvas, Offset((side - tp.width) / 2, (side - tp.height) / 2));
  final image = await recorder.endRecording().toImage(side.toInt(), side.toInt());
  final png = await image.toByteData(format: ui.ImageByteFormat.png);
  final file = File(p.join(dir, '$name.png'));
  await file.writeAsBytes(png!.buffer.asUint8List());
  return file.path;
}

Future<void> _seed() async {
  if (!isAppDataDirPinned || !appDataDirName.endsWith('_screenshots')) {
    throw StateError('Run with --dart-define=DPM_DATA_DIR=daw_project_manager_screenshots '
        '— this wipes the library it runs on.');
  }
  final dataDir = Directory(await getLocalAppDataPath());
  if (await dataDir.exists()) await dataDir.delete(recursive: true);

  final profiles = await ProfileRepository.init();
  final starter = profiles.getCurrentProfileId()!;
  await ProjectRepository.init(profiles);
  final demo = await DemoDataService().generate(profiles);
  await profiles.setCurrentProfileId(demo.id);
  if (starter != demo.id) await profiles.deleteProfile(starter);

  final covers = Directory(await getProjectCoverArtPath());
  await covers.create(recursive: true);
  final box = await Hive.openBox<MusicProject>('${demo.id}_projects');
  final rows = box.values.where((x) => !x.isStackMember).toList()
    ..sort((a, b) => a.displayName.compareTo(b.displayName));

  final palette = [
    (Colors.deepPurple, Colors.pinkAccent),
    (Colors.teal, Colors.lightGreenAccent),
    (Colors.orange, Colors.red),
    (Colors.indigo, Colors.cyan),
    (Colors.brown, Colors.amber),
    (Colors.blueGrey, Colors.lightBlueAccent),
  ];
  // Every other row gets a cover, so decorated and plain rows sit side by side.
  var c = 0;
  for (final (i, project) in rows.indexed) {
    if (i.isOdd || c >= palette.length) continue;
    final (a, b) = palette[c++];
    final path = await _cover(covers.path, project.id, a, b, project.displayName[0]);
    var updated = project.copyWith(thumbnailPath: path);
    // One covered row with a very long name, to show the "…".
    if (c == 1) {
      updated = updated.copyWith(
        customDisplayName:
            'Togetherness (Dolby Atmos Master 48k 7.1.4) – Extended Club Version Final Approved',
      );
    }
    await box.put(project.id, updated);
  }
  // And a long name on a row with no cover.
  final plain = rows[1];
  await box.put(
    plain.id,
    plain.copyWith(customDisplayName: 'MotorWayToO v24 [48k Album] Stereo Master with Alternate Intro'),
  );

  final settings = await Hive.openBox<String>('settings');
  await settings.putAll({
    'onboardingComplete': 'true',
    'hidePinnedLibraryWarning': 'true',
    'warnBeforeQuit': 'false',
    'closeToTray': 'false',
    'dashboardViewMode': 'table',
  });
  final appSettings = await Hive.openBox<String>('app_settings');
  await appSettings.putAll({'syncOnStartup': 'false', 'autoBackupInterval': 'off'});
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('list view cover preview', (tester) async {
    tester.view.physicalSize = _size;
    tester.view.devicePixelRatio = 1;
    await _seed();
    WidgetsApp.debugAllowBannerOverride = false;
    app.main(const []);

    final end = DateTime.now().add(const Duration(seconds: 60));
    while (find.textContaining('Togetherness').evaluate().isEmpty) {
      if (DateTime.now().isAfter(end)) throw TestFailure('The list never showed');
      await tester.pump(const Duration(milliseconds: 100));
    }
    // Covers are decoded off the UI thread: give them real time to arrive.
    for (var i = 0; i < 30; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump(const Duration(milliseconds: 100));
    }

    Future<void> shot(String name, {Rect? crop, double ratio = 1}) async {
      final view = tester.binding.renderViews.first;
      final layer = view.debugLayer! as OffsetLayer;
      final bounds = (crop ?? Offset.zero & view.size).intersect(Offset.zero & view.size);
      final image = await layer.toImage(bounds, pixelRatio: ratio);
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File(p.join('build', 'preview_screenshots', name));
      await file.parent.create(recursive: true);
      await file.writeAsBytes(png!.buffer.asUint8List());
      debugPrint('SCREENSHOT $name');
    }

    await shot('1-projects-list.png');
    // A closer look at the Name column: from the left of the first name to a
    // little past it, a dozen rows down.
    final name = tester.getRect(find.textContaining('Togetherness').first);
    final crop = Rect.fromLTWH(
      (name.left - 120).clamp(0, _size.width),
      (name.top - 200).clamp(0, _size.height),
      700,
      560,
    );
    await shot('2-name-column-close-up.png', crop: crop, ratio: 2);
  });
}
