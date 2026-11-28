// Preview pictures of v3.0.6 — File Type column, standalone audio rows and a
// project's Audio files section — from the real app on a demo library with
// invented songs, never a real one. Audio and the WaveLab montage are built
// here with real headers (an RF64 Dolby Atmos ADM master included) and no
// sound in them.
//
//   xvfb-run flutter test integration_test/screenshots/audio_preview_test.dart -d linux \
//     --dart-define=DPM_DATA_DIR=daw_project_manager_screenshots \
//     --dart-define=DPM_HIDE_VERSION=true --dart-define=DPM_SCREENSHOTS=true
//
// Writes build/preview_screenshots/*.png. A tool, not part of CI's suite.

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;

import 'package:daw_project_manager/main.dart' as app;
import 'package:daw_project_manager/repository/profile_repository.dart';
import 'package:daw_project_manager/repository/project_repository.dart';
import 'package:daw_project_manager/services/demo_data_service.dart';
import 'package:daw_project_manager/utils/app_paths.dart';

import '../../test/helpers/audio_file_builder.dart';

const _size = Size(1920, 1080);
const _song = 'Harbour Lights Atmos';

Future<void> _seed() async {
  if (!isAppDataDirPinned || !appDataDirName.endsWith('_screenshots')) {
    throw StateError('Run with --dart-define=DPM_DATA_DIR=daw_project_manager_screenshots');
  }
  final dataDir = Directory(await getLocalAppDataPath());
  if (await dataDir.exists()) await dataDir.delete(recursive: true);

  final profiles = await ProfileRepository.init();
  final starter = profiles.getCurrentProfileId()!;
  await ProjectRepository.init(profiles);
  final demo = await DemoDataService().generate(profiles);
  await profiles.setCurrentProfileId(demo.id);
  if (starter != demo.id) await profiles.deleteProfile(starter);

  // An invented WaveLab Atmos project, laid out as WaveLab 13 saves one.
  final lib = p.join(dataDir.path, 'Preview Library');
  final song = p.join(lib, _song);
  Future<File> write(String rel, List<int> bytes) async {
    final f = File(p.join(song, rel));
    await f.parent.create(recursive: true);
    await f.writeAsBytes(bytes);
    return f;
  }

  await write('audio/bed_1_1.wav',
      AudioFileBuilder.wav(channels: 10, mask: 0x63F | 0x1000 | 0x4000, frames: 480));
  await write('audio/Object 11_1.wav', AudioFileBuilder.wav(channels: 1, frames: 480));
  await write('audio/Object 12_1.wav', AudioFileBuilder.wav(channels: 1, frames: 480));
  await write('$_song ADM.wav', AudioFileBuilder.admMaster(frames: 480));
  await write('$_song Stereo Master.wav', AudioFileBuilder.wav(frames: 48000 * 3));
  await write('Renders/$_song Binaural.wav', AudioFileBuilder.wav(frames: 48000 * 3));
  await write('Stems/$_song Drums Stem.wav', AudioFileBuilder.wav(frames: 4800));
  await write('$_song 714 Print.wav',
      AudioFileBuilder.wav(channels: 12, mask: 0x2D63F, frames: 480));
  final mon = await write('$_song.mon', AudioFileBuilder.waveLabMontage([
    ('admM', '/Volumes/Old Drive/ADM/$_song ADM.wav'),
    ('admM', '$_song ADM.wav'),
    ('P8\x00\x00', '/Volumes/Old Drive/$_song/audio/bed_1_1.wav|audio/bed_1_1.wav'),
    ('P8\x00\x00', '/Volumes/Old Drive/$_song/audio/Object 11_1.wav|audio/Object 11_1.wav'),
    ('P8\x00\x00', '/Volumes/Old Drive/$_song/audio/Object 12_1.wav|audio/Object 12_1.wav'),
    ('P8\x00\x00', '/Volumes/Old Drive/$_song/audio/Object 13_1.wav|audio/Object 13_1.wav'),
  ]));
  final master = File(p.join(lib, 'Masters', 'Glass Harbour Master.wav'));
  await master.parent.create(recursive: true);
  await master.writeAsBytes(AudioFileBuilder.wav(frames: 48000 * 2));

  final repo = await ProjectRepository.initWithProfile(profiles, demo.id);
  await repo.upsertManyFromFileSystemEntities([mon, master]);

  final settings = await Hive.openBox<String>('settings');
  await settings.putAll({
    'onboardingComplete': 'true',
    'hidePinnedLibraryWarning': 'true',
    'warnBeforeQuit': 'false',
    'closeToTray': 'false',
    'dashboardViewMode': 'table',
    'projectDetailLayout': 'sectioned',
    'standaloneAudioEnabled': 'true',
  });
  final appSettings = await Hive.openBox<String>('app_settings');
  await appSettings.putAll({'syncOnStartup': 'false', 'autoBackupInterval': 'off'});
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('v3.0.6 audio preview', (tester) async {
    tester.view.physicalSize = _size;
    tester.view.devicePixelRatio = 1;
    await _seed();
    final errorWidgetBuilder = ErrorWidget.builder;
    WidgetsApp.debugAllowBannerOverride = false;
    app.main(const []);

    Future<void> pumpFor(int tenths) async {
      for (var i = 0; i < tenths; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    Future<void> until(Finder f, {int tenths = 600}) async {
      for (var i = 0; i < tenths; i++) {
        if (f.evaluate().isNotEmpty) return;
        await pumpFor(1);
      }
      throw TestFailure('Never showed $f');
    }

    Future<void> shot(String name) async {
      await pumpFor(10);
      final view = tester.binding.renderViews.first;
      final layer = view.debugLayer! as OffsetLayer;
      final image = await layer.toImage(Offset.zero & view.size, pixelRatio: 1);
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File(p.join('build', 'preview_screenshots', name));
      await file.parent.create(recursive: true);
      await file.writeAsBytes(png!.buffer.asUint8List());
      debugPrint('SCREENSHOT $name');
    }

    final failures = <String>[];
    Future<void> step(String name, Future<void> Function() body) async {
      try {
        await body();
      } catch (e) {
        failures.add('$name: $e');
        debugPrint('SKIPPED $name: $e');
        await shot('error-$name.png');
      }
    }

    await until(find.text(_song));
    await pumpFor(20);

    await step('list', () async {
      await shot('1-projects-list-file-type.png');
    });

    await step('detail', () async {
      final target = find.text(_song).first;
      final mouse = await tester.createGesture(
          kind: PointerDeviceKind.mouse, buttons: kSecondaryMouseButton);
      await mouse.addPointer(location: tester.getCenter(target));
      await mouse.down(tester.getCenter(target));
      await tester.pump();
      await mouse.up();
      await mouse.removePointer();
      await pumpFor(5);
      await tester.tap(find.text('View Details').first);
      await pumpFor(15);
      await until(find.text('Audio files').hitTestable());
      await tester.tap(find.text('Audio files').hitTestable().first);
      await pumpFor(10);
      // Filled by itself (from the index, or read on opening): no button.
      await until(find.textContaining('Confirmed by the session'));
      await pumpFor(10);
      await shot('2-project-audio-files.png');
      // The rest of the list, scrolled.
      await tester.drag(find.textContaining('Confirmed by the session'),
          const Offset(0, -500));
      await pumpFor(5);
      await shot('3-project-audio-files-scrolled.png');
    });

    await step('filter', () async {
      await tester.tap(find.byIcon(Icons.arrow_back).hitTestable().first);
      await pumpFor(15);
      await tester.tap(find.text('All audio').hitTestable().first);
      await pumpFor(5);
      await tester.tap(find.text('With an ADM master').hitTestable().last);
      await pumpFor(10);
      await shot('4-filter-adm-masters.png');
    });

    ErrorWidget.builder = errorWidgetBuilder;
    if (failures.isNotEmpty) debugPrint('FAILURES: ${failures.join(' | ')}');
  });
}
