import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import 'core/jobs.dart';
import 'core/library.dart';
import 'core/paths.dart';
import 'core/player.dart';
import 'core/settings.dart';
import 'core/setup.dart';
import 'core/sidecar.dart';
import 'core/update_check.dart';
import 'core/version.dart';
import 'ui/about.dart';
import 'ui/extend_page.dart';
import 'ui/generate_page.dart';
import 'ui/library_page.dart';
import 'ui/models_page.dart';
import 'ui/settings_page.dart';
import 'ui/widgets.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  final paths = AppPaths.init();
  final settings = await Settings.load(paths);
  final library = Library(settings, paths);
  await library.refresh();
  final sidecar = Sidecar(settings);
  final queue = JobQueue(sidecar, settings, library);
  final setup = EngineSetup(settings, sidecar);
  runApp(MultiProvider(
    providers: [
      ChangeNotifierProvider.value(value: settings),
      ChangeNotifierProvider.value(value: library),
      ChangeNotifierProvider.value(value: sidecar),
      ChangeNotifierProvider.value(value: queue),
      ChangeNotifierProvider.value(value: setup),
      ChangeNotifierProvider(create: (_) => AudioPlayerModel()),
      ChangeNotifierProvider(create: (_) => AppNav()),
    ],
    child: const Yue2StudioApp(),
  ));
  // Warm the engine in the background so the first job starts quickly.
  unawaited(sidecar.ensureStarted().then((_) => sidecar.refreshInfo()).catchError((_) => <String, dynamic>{}));
  final snapshots = Platform.environment['YUE2_STUDIO_SNAPSHOT'];
  if (snapshots != null && snapshots.isNotEmpty) unawaited(_snapshotPages(snapshots));
  final selftest = Platform.environment['YUE2_STUDIO_SELFTEST'];
  if (selftest != null && selftest.isNotEmpty) unawaited(_selfTest(selftest, queue, library));
}

final snapshotKey = GlobalKey();

/// YUE2_STUDIO_SNAPSHOT=(dir): render every page of the running app to dir/page-N.png from its own
/// layer tree (works without screen-recording permission or an unlocked display).
Future<void> _snapshotPages(String dir) async {
  await Directory(dir).create(recursive: true);
  await Future.delayed(const Duration(seconds: 4));
  const names = ['generate', 'library', 'extend', 'models', 'settings'];
  for (var i = 0; i < names.length; i++) {
    final ctx = snapshotKey.currentContext;
    if (ctx == null || !ctx.mounted) break;
    Provider.of<AppNav>(ctx, listen: false).go(i);
    await Future.delayed(const Duration(seconds: 3));
    final boundary = snapshotKey.currentContext?.findRenderObject() as RenderRepaintBoundary?;
    if (boundary == null) break;
    final image = await boundary.toImage(pixelRatio: 1.5);
    final bytes = await image.toByteData(format: ImageByteFormat.png);
    await File(p.join(dir, 'page-$i-${names[i]}.png')).writeAsBytes(bytes!.buffer.asUint8List());
  }
  await File(p.join(dir, 'done')).writeAsString('ok');
}

ThemeData _theme(Brightness b) {
  final scheme = ColorScheme.fromSeed(seedColor: const Color(0xFFF2B35A), brightness: b);
  return ThemeData(
    colorScheme: b == Brightness.dark ? scheme.copyWith(surface: const Color(0xFF12111C)) : scheme,
    useMaterial3: true,
    visualDensity: VisualDensity.compact,
  );
}

class Yue2StudioApp extends StatefulWidget {
  const Yue2StudioApp({super.key});

  @override
  State<Yue2StudioApp> createState() => _Yue2StudioAppState();
}

class _Yue2StudioAppState extends State<Yue2StudioApp> {
  late final AppLifecycleListener _lifecycle;
  final _messenger = GlobalKey<ScaffoldMessengerState>();

  @override
  void initState() {
    super.initState();
    final sidecar = context.read<Sidecar>();
    _lifecycle = AppLifecycleListener(onExitRequested: () async {
      await sidecar.stop();
      return AppExitResponse.exit;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeCheckUpdate());
  }

  Future<void> _maybeCheckUpdate() async {
    final s = context.read<Settings>();
    if (!s.updateCheckEnabled) return;
    try {
      final u = await checkForUpdate(s.updateUrl);
      if (u.newer) {
        _messenger.currentState?.showMaterialBanner(MaterialBanner(
          content: Text('YuE2 Studio ${u.latest} is available (you have $appVersion).${u.url != null ? ' ${u.url}' : ''}'),
          actions: [TextButton(onPressed: () => _messenger.currentState?.hideCurrentMaterialBanner(), child: const Text('Dismiss'))],
        ));
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: appName,
      debugShowCheckedModeBanner: false,
      scaffoldMessengerKey: _messenger,
      theme: _theme(Brightness.light),
      darkTheme: _theme(Brightness.dark),
      themeMode: ThemeMode.system,
      home: RepaintBoundary(key: snapshotKey, child: const Shell()),
    );
  }
}

class Shell extends StatelessWidget {
  const Shell({super.key});

  static const _pages = [GeneratePage(), LibraryPage(), ExtendPage(), ModelsPage(), SettingsPage()];

  @override
  Widget build(BuildContext context) {
    final nav = context.watch<AppNav>();
    final q = context.watch<JobQueue>();
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      body: Column(children: [
        Expanded(
          child: Row(children: [
            NavigationRail(
              selectedIndex: nav.index,
              onDestinationSelected: nav.go,
              labelType: NavigationRailLabelType.all,
              leading: Padding(
                padding: const EdgeInsets.only(top: 8, bottom: 12),
                child: InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: () => showAboutYue(context),
                  child: Tooltip(message: 'About $appName', child: Image.asset('assets/icon-macos-1024.png', width: 52, height: 52)),
                ),
              ),
              trailing: Expanded(
                child: Align(
                  alignment: Alignment.bottomCenter,
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      IconButton(tooltip: 'About', icon: const Icon(Icons.info_outline), onPressed: () => showAboutYue(context)),
                      Text('v$appVersion', style: TextStyle(fontSize: 10, color: cs.onSurfaceVariant)),
                    ]),
                  ),
                ),
              ),
              destinations: [
                NavigationRailDestination(
                  icon: Badge(isLabelVisible: q.running != null, child: const Icon(Icons.auto_awesome_outlined)),
                  selectedIcon: const Icon(Icons.auto_awesome),
                  label: const Text('Generate'),
                ),
                const NavigationRailDestination(icon: Icon(Icons.library_music_outlined), selectedIcon: Icon(Icons.library_music), label: Text('Library')),
                const NavigationRailDestination(icon: Icon(Icons.queue_music_outlined), selectedIcon: Icon(Icons.queue_music), label: Text('Extend')),
                const NavigationRailDestination(icon: Icon(Icons.memory_outlined), selectedIcon: Icon(Icons.memory), label: Text('Models')),
                const NavigationRailDestination(icon: Icon(Icons.settings_outlined), selectedIcon: Icon(Icons.settings), label: Text('Settings')),
              ],
            ),
            const VerticalDivider(width: 1),
            Expanded(child: IndexedStack(index: nav.index, children: _pages)),
          ]),
        ),
        const JobStrip(),
        const PlayerBar(),
      ]),
    );
  }
}

/// Headless end-to-end check through the real app path (Dart queue -> sidecar -> engine):
/// YUE2_STUDIO_SELFTEST=(report dir) generates a short song, extends it by 15 s and writes
/// selftest.json. YUE2_STUDIO_SELFTEST_QUIT=1 exits afterwards.
Future<void> _selfTest(String reportDir, JobQueue q, Library lib) async {
  final report = <String, dynamic>{'started': DateTime.now().toIso8601String(), 'backend': q.settings.backend};
  Future<Job> run(String kind, String title, Map<String, dynamic> args) async {
    final job = q.add(kind, title, args);
    final sw = Stopwatch()..start();
    while (job.active) {
      await Future.delayed(const Duration(milliseconds: 500));
    }
    report['${kind}_wall_seconds'] = sw.elapsedMilliseconds / 1000;
    return job;
  }

  try {
    final g = await run('generate', 'Selftest song', {
      'style': 'upbeat indie pop, female vocal, acoustic guitar, bright',
      'lyrics': '[Verse]\nPaper boats along the shore\nCounting waves and nothing more\n[Chorus]\nHold the light, hold it near\nSummer is already here\n',
      'mode': 'off',
      'seed': 2026,
      'precision': '8bit',
      'steps': 8,
      'max_seconds': 25,
    });
    report['generate'] = {'status': g.status.name, 'error': g.error, 'dir': g.outputDir, 'result': g.result};
    if (g.status != JobStatus.done) throw StateError('generate failed: ${g.error}');
    final secs = (g.result!['audio_seconds'] as num).toDouble();
    final e = await run('extend', 'Selftest song (extended +15 s)', {
      'source_dir': g.outputDir,
      'section_start': (secs - 10).clamp(0, secs),
      'section_end': null,
      'section_seconds': 10,
      'add_seconds': 15,
      'style': 'upbeat indie pop, female vocal, acoustic guitar, bright',
      'lyrics': '[Verse]\nPaper boats along the shore\nCounting waves and nothing more\n[Chorus]\nHold the light, hold it near\nSummer is already here\n',
      'mode': 'off',
      'seed': 2027,
      'precision': '8bit',
      'steps': 8,
      'crossfade': 2.0,
    });
    report['extend'] = {'status': e.status.name, 'error': e.error, 'dir': e.outputDir, 'result': e.result};
    report['ok'] = e.status == JobStatus.done;
  } catch (err) {
    report['ok'] = false;
    report['error'] = err.toString();
  }
  report['finished'] = DateTime.now().toIso8601String();
  await lib.refresh();
  await Directory(reportDir).create(recursive: true);
  await File(p.join(reportDir, 'selftest.json')).writeAsString(const JsonEncoder.withIndent('  ').convert(report));
  if (Platform.environment['YUE2_STUDIO_SELFTEST_QUIT'] == '1') {
    await q.sidecar.stop();
    exit(report['ok'] == true ? 0 : 1);
  }
}
