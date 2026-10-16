import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../core/app_info.dart';
import '../core/settings.dart';
import '../core/studio.dart';
import '../core/update_check.dart';
import '../state/nav.dart';
import 'screens/setup_screen.dart';
import 'shell.dart';
import 'theme.dart';

final snapshotKey = GlobalKey();

class StudioApp extends StatefulWidget {
  const StudioApp({super.key});

  @override
  State<StudioApp> createState() => _StudioAppState();
}

class _StudioAppState extends State<StudioApp> {
  late final AppLifecycleListener _lifecycle;
  final _messenger = GlobalKey<ScaffoldMessengerState>();

  @override
  void initState() {
    super.initState();
    final studio = context.read<Studio>();
    _lifecycle = AppLifecycleListener(onExitRequested: () async {
      await studio.engine?.shutdown();
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
          content: Text('Version ${u.latest} is available.${u.url != null ? ' ${u.url}' : ''}'),
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
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      themeMode: ThemeMode.system,
      home: RepaintBoundary(key: snapshotKey, child: const _Root()),
    );
  }
}

class _Root extends StatelessWidget {
  const _Root();

  @override
  Widget build(BuildContext context) {
    final studio = context.watch<Studio>();
    final nav = context.watch<AppNav>();
    return studio.needsSetup || nav.setupOpen ? const SetupScreen() : const Shell();
  }
}

/// `STUDIO_SNAPSHOT=dir`: render every destination to `dir/page-N.png` from the app's own layer
/// tree (works without screen-recording permission).
Future<void> snapshotPages(String dir, AppNav nav) async {
  await Directory(dir).create(recursive: true);
  await Future.delayed(const Duration(seconds: 4));
  for (final d in Dest.values) {
    nav.go(d);
    await Future.delayed(const Duration(seconds: 2));
    final boundary = snapshotKey.currentContext?.findRenderObject() as RenderRepaintBoundary?;
    if (boundary == null) break;
    final image = await boundary.toImage(pixelRatio: 1.5);
    final bytes = await image.toByteData(format: ImageByteFormat.png);
    await File(p.join(dir, 'page-${d.index}-${d.name}.png')).writeAsBytes(bytes!.buffer.asUint8List());
  }
  await File(p.join(dir, 'done')).writeAsString('ok');
}
