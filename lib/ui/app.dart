import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/app_info.dart';
import '../core/settings.dart';
import '../core/studio.dart';
import '../core/update_check.dart';
import '../state/nav.dart';
import 'screens/setup_screen.dart';
import 'screens/studio_screen.dart';
import 'snapshot.dart';
import 'theme.dart';
import 'widgets/sleeve.dart';

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
    if (!s.updateCheckEnabled || Snapshot.active) return;
    try {
      final u = await checkForUpdate(s.updateUrl);
      final ctx = _messenger.currentContext;
      if (u.newer && ctx != null && ctx.mounted) showLine(ctx, 'Version ${u.latest} is out${u.url != null ? ' · ${u.url}' : ''}');
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
      theme: buildTheme(),
      themeMode: ThemeMode.dark,
      builder: Snapshot.active ? (context, child) => SnapshotFrame(child: child!) : null,
      home: const _Root(),
    );
  }
}

class _Root extends StatelessWidget {
  const _Root();

  @override
  Widget build(BuildContext context) {
    if (Snapshot.active) return const SnapshotScreen();
    final studio = context.watch<Studio>();
    final nav = context.watch<AppNav>();
    return studio.needsSetup || nav.setupOpen ? const SetupScreen() : const StudioScreen();
  }
}
