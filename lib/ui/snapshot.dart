import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../core/library/library.dart';
import 'screens/catalogue_screen.dart';
import 'screens/extend_screen.dart';
import 'screens/record_sheet.dart';
import 'screens/settings_screen.dart';
import 'screens/setup_screen.dart';
import 'screens/song_screen.dart';
import 'screens/studio_screen.dart';

/// One capture: a screen at a logical size, written as PNG.
class Shot {
  Shot(this.screen, this.size, this.file, {this.ratio = 1});
  final String screen;
  final Size size;
  final String file;
  final double ratio;

  /// `main@576x1024=hero-repro.png`, optional `@2` ratio suffix after the size.
  static Shot? parse(String s) {
    final m = RegExp(r'^(\w+)@(\d+)x(\d+)(?:@([\d.]+))?=(.+)$').firstMatch(s.trim());
    if (m == null) return null;
    return Shot(m[1]!, Size(double.parse(m[2]!), double.parse(m[3]!)), m[5]!, ratio: double.tryParse(m[4] ?? '') ?? 1);
  }
}

/// `STUDIO_SNAPSHOT=<dir>` with `STUDIO_SNAPSHOT_SHOTS="main@576x1024=hero.png;catalogue@390x844@2=c.png"`:
/// renders each screen at exactly that logical size from the app's own layer tree (independent of
/// the window and of screen-recording permission), writes `<dir>/<file>`, then `<dir>/done`.
abstract final class Snapshot {
  static final active = (Platform.environment['STUDIO_SNAPSHOT'] ?? '').isNotEmpty;
  static final current = ValueNotifier<Shot?>(null);
  static final key = GlobalKey();
  static final navigator = GlobalKey<NavigatorState>();

  /// Puts the app into the state a shot needs (demo states, long lyrics); set by main.
  static Future<void> Function(Shot shot)? prepare;

  static List<Shot> get shots => [
        for (final s in (Platform.environment['STUDIO_SNAPSHOT_SHOTS'] ?? 'main@576x1024=main.png').split(';'))
          if (Shot.parse(s) case final shot?) shot,
      ];

  static Future<void> run() async {
    final dir = Platform.environment['STUDIO_SNAPSHOT']!;
    await Directory(dir).create(recursive: true);
    await Future.delayed(const Duration(seconds: 2));
    for (final s in shots) {
      navigator.currentState?.popUntil((r) => r.isFirst);
      await prepare?.call(s);
      current.value = s;
      await Future.delayed(const Duration(milliseconds: 2500));
      await WidgetsBinding.instance.endOfFrame;
      final boundary = key.currentContext?.findRenderObject() as RenderRepaintBoundary?;
      if (boundary == null) continue;
      final image = await boundary.toImage(pixelRatio: s.ratio);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      await File(p.join(dir, s.file)).writeAsBytes(bytes!.buffer.asUint8List());
    }
    await File(p.join(dir, 'done')).writeAsString('ok');
    if (Platform.environment['STUDIO_SNAPSHOT_QUIT'] == '1') exit(0);
  }
}

/// Lays the app out at the shot's size, whatever the window is.
class SnapshotFrame extends StatelessWidget {
  const SnapshotFrame({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<Shot?>(
        valueListenable: Snapshot.current,
        builder: (context, shot, _) {
          if (shot == null) return const ColoredBox(color: Colors.black);
          final mq = MediaQuery.of(context).copyWith(
            size: shot.size,
            padding: EdgeInsets.zero,
            viewPadding: EdgeInsets.zero,
            viewInsets: EdgeInsets.zero,
            textScaler: TextScaler.noScaling,
            disableAnimations: true,
          );
          return OverflowBox(
            alignment: Alignment.topLeft,
            minWidth: shot.size.width,
            maxWidth: shot.size.width,
            minHeight: shot.size.height,
            maxHeight: shot.size.height,
            child: MediaQuery(
              data: mq,
              child: RepaintBoundary(key: Snapshot.key, child: KeyedSubtree(key: ValueKey(shot.file), child: child)),
            ),
          );
        },
      );
}

class SnapshotScreen extends StatelessWidget {
  const SnapshotScreen({super.key});

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<Shot?>(
        valueListenable: Snapshot.current,
        builder: (context, shot, _) {
          final lib = context.read<Library>();
          String idOf(int n) => lib.byNumber(n)?.id ?? (lib.songs.isEmpty ? '' : lib.songs.first.id);
          return switch (shot?.screen) {
            'catalogue' => const CatalogueScreen(),
            'sheet' => _SheetOpener(key: ValueKey(shot!.file)),
            'song' => SongScreen(idOf(14)),
            'extend' => ExtendScreen(sourceId: idOf(14)),
            'setup' => const SetupScreen(),
            'settings' => const SettingsScreen(),
            _ => const StudioScreen(),
          };
        },
      );
}

/// The studio with the recording sheet open.
class _SheetOpener extends StatefulWidget {
  const _SheetOpener({super.key});

  @override
  State<_SheetOpener> createState() => _SheetOpenerState();
}

class _SheetOpenerState extends State<_SheetOpener> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) showRecordSheet(context);
    });
  }

  @override
  Widget build(BuildContext context) => const StudioScreen();
}
