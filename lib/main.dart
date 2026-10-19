import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'core/demo.dart';
import 'core/engine/engine.dart';
import 'core/engine/hardware.dart';
import 'core/jobs/job_queue.dart';
import 'core/library/envelopes.dart';
import 'core/library/library.dart';
import 'core/models/registry.dart';
import 'core/paths.dart';
import 'core/playback/playback.dart';
import 'core/player.dart';
import 'core/selftest.dart';
import 'core/settings.dart';
import 'core/setup/model_setup.dart';
import 'core/studio.dart';
import 'state/extend_form.dart';
import 'state/generate_form.dart';
import 'state/library_view.dart';
import 'state/nav.dart';
import 'state/take.dart';
import 'ui/app.dart';
import 'ui/screens/studio_screen.dart' show studioScrollToEnd;
import 'ui/snapshot.dart';
import 'ui/ui_test.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  PlaybackBackend.ensureInitialized();
  final env = Platform.environment;
  final paths = await AppPaths.init();
  final settings = await Settings.load(paths);
  final demo = env['STUDIO_DEMO'] ?? '';
  if (demo.isNotEmpty) await Demo.seed(demo, settings);
  final registry = await ModelRegistry.load();
  final hardware = await Hardware.detect();
  final library = Library(settings, paths);
  await library.refresh();
  final studio = Studio(settings: settings, registry: registry, hardware: hardware, library: library);
  final setup = ModelSetup(studio);
  // Desktop: model files that would fail on Record (such as the 0.4.4 MLX folder layout) send
  // the user back to setup, which repairs them in place.
  if (!Platform.isAndroid && demo.isEmpty && settings.setupComplete && studio.engineDescriptor != null) {
    if (!(await setup.refresh()).ready) settings.setupComplete = false;
  }
  if (settings.setupComplete && demo.isEmpty) await studio.rebuildEngine();
  final queue = JobQueue(studio, library);
  final player = AudioPlayerModel();
  final nav = AppNav();
  final envelopes = Envelopes(settings);
  if (demo.isNotEmpty) await Demo.live(demo, library, queue, envelopes);
  final take = TakeState(studio, library, queue, player, envelopes);
  final form = GenerateForm(studio, queue);
  // A finished job's audio changed: drop any stale plot so it is recomputed.
  library.addListener(() {
    for (final s in library.songs) {
      if (s.status.name == 'done') envelopes.of(s);
    }
  });
  runApp(MultiProvider(
    providers: [
      ChangeNotifierProvider.value(value: settings),
      ChangeNotifierProvider.value(value: studio),
      ChangeNotifierProvider.value(value: library),
      ChangeNotifierProvider.value(value: queue),
      ChangeNotifierProvider.value(value: setup),
      ChangeNotifierProvider.value(value: player),
      ChangeNotifierProvider.value(value: nav),
      ChangeNotifierProvider.value(value: envelopes),
      ChangeNotifierProvider.value(value: take),
      ChangeNotifierProvider.value(value: form),
      ChangeNotifierProvider(create: (_) => ExtendForm(studio, queue, library)),
      ChangeNotifierProvider(create: (_) => LibraryView(studio, library, queue, player)),
    ],
    child: const StudioApp(),
  ));
  // Start the queue (and warm the engine) whenever an engine exists.
  void startQueue() {
    if (studio.engine != null) unawaited(queue.start());
  }

  Engine? started;
  studio.addListener(() {
    if (studio.engine != null && !identical(started, studio.engine)) {
      started = studio.engine;
      startQueue();
    }
  });
  if (studio.engine != null) {
    started = studio.engine;
    startQueue();
  }
  if (Snapshot.active) {
    FlutterError.onError = (d) {
      final lines = (d.stack?.toString() ?? '').split('\n');
      stderr.writeln('SNAPSHOT ERROR: ${d.exceptionAsString()}\n${lines.take(40).join('\n')}');
    };
    final original = form.lyrics.text;
    Snapshot.prepare = (shot) async {
      studioScrollToEnd.value = shot.screen == 'mainlong';
      // The sheet: the draft for the next song, or the shown song's own words.
      if (shot.screen == 'draft' || shot.screen == 'reuse') {
        take.draft();
      } else {
        take.listen();
      }
      if (shot.screen != 'reuse') form.lyrics.text = shot.screen == 'mainlong' ? Demo.forty() : original;
      if (shot.screen == 'reuse') {
        final src = library.byNumber(14);
        if (src != null) form.reuse(src, label: 'From LRS-014');
      }
      if (demo.isNotEmpty && const ['idle', 'playing', 'error'].contains(shot.screen)) {
        await Demo.state(shot.screen, demo, library, queue, player);
      }
    };
    unawaited(Snapshot.run());
  }
  if (UiTest.active) unawaited(UiTest(env['STUDIO_UITEST']!, library, form).run());
  if ((env['STUDIO_SELFTEST'] ?? '').isNotEmpty) unawaited(runSelfTest(env['STUDIO_SELFTEST']!, studio, queue, library));
}
