import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:provider/provider.dart';

import 'core/demo.dart';
import 'core/engine/engine.dart';
import 'core/engine/hardware.dart';
import 'core/jobs/job_queue.dart';
import 'core/library/envelopes.dart';
import 'core/library/library.dart';
import 'core/models/registry.dart';
import 'core/paths.dart';
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
import 'ui/snapshot.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
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
  if (settings.setupComplete && demo.isEmpty) await studio.rebuildEngine();
  final queue = JobQueue(studio, library);
  final setup = ModelSetup(studio);
  final player = AudioPlayerModel();
  final nav = AppNav();
  final envelopes = Envelopes(settings);
  if (demo.isNotEmpty) await Demo.live(demo, library, queue, envelopes);
  final take = TakeState(studio, library, queue, player, envelopes);
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
      ChangeNotifierProvider(create: (_) => GenerateForm(studio, queue)),
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
    unawaited(Snapshot.run());
  }
  if ((env['STUDIO_SELFTEST'] ?? '').isNotEmpty) unawaited(runSelfTest(env['STUDIO_SELFTEST']!, studio, queue, library));
}
