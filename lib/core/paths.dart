import 'dart:io';

import 'package:path/path.dart' as p;

import 'platform/android_bridge.dart';

/// Where the app keeps its data.
/// macOS: ~/Library/Application Support/Localhost Recording Studio
/// Linux: $XDG_DATA_HOME/localhost-recording-studio (default ~/.local/share/...)
/// Android: the app-specific external files dir (`Android/data/<id>/files`)
class AppPaths {
  AppPaths._(this.dataDir);

  final String dataDir;

  static late AppPaths instance;

  static String get home => Platform.environment['HOME'] ?? '/';

  static Future<AppPaths> init() async {
    String dir;
    final override = Platform.environment['STUDIO_DATA_DIR'];
    if (override != null && override.isNotEmpty) {
      dir = override;
    } else if (Platform.isAndroid) {
      final m = await AndroidBridge.map('paths');
      dir = m['data'] as String;
    } else if (Platform.isMacOS) {
      dir = p.join(home, 'Library', 'Application Support', 'Localhost Recording Studio');
    } else {
      final xdg = Platform.environment['XDG_DATA_HOME'];
      dir = p.join((xdg != null && xdg.isNotEmpty) ? xdg : p.join(home, '.local', 'share'), 'localhost-recording-studio');
    }
    Directory(dir).createSync(recursive: true);
    instance = AppPaths._(dir);
    return instance;
  }

  String get settingsFile => p.join(dataDir, 'settings.json');
  String get libraryDir => p.join(dataDir, 'library');
  String get modelsDir => p.join(dataDir, 'models');
  String get sidecarDir => p.join(dataDir, 'sidecar');
  String get sidecarVenv => p.join(dataDir, 'sidecar-venv');
  String get enginesDir => p.join(dataDir, 'engines');
  String get logsDir => p.join(dataDir, 'logs');

  /// Folder for one runtime's checkout (e.g. a git clone built or synced by the setup flow).
  String runtimeDir(String name) => p.join(enginesDir, name);

  /// Folder holding one model format's files.
  String modelDir(String modelId, String formatId) => p.join(modelsDir, modelId, formatId);

  static String venvPython(String venv) =>
      Platform.isWindows ? p.join(venv, 'Scripts', 'python.exe') : p.join(venv, 'bin', 'python');

  /// Locate an executable on PATH plus the usual non-PATH spots of GUI apps.
  static String? which(String name, {List<String> extra = const []}) {
    final dirs = <String>[
      ...extra,
      ...(Platform.environment['PATH'] ?? '').split(':'),
      '/opt/homebrew/bin',
      '/usr/local/bin',
      '/usr/bin',
      p.join(home, '.local', 'bin'),
      p.join(home, '.cargo', 'bin'),
    ];
    for (final d in dirs) {
      if (d.isEmpty) continue;
      final f = File(p.join(d, name));
      if (f.existsSync()) return f.path;
    }
    return null;
  }

  static String? ffmpeg([String? hint]) {
    if (hint != null && hint.isNotEmpty && File(hint).existsSync()) return hint;
    return which('ffmpeg');
  }

  /// Free bytes on the volume holding [path].
  static Future<int?> freeBytes(String path) async {
    if (Platform.isAndroid) {
      return (await AndroidBridge.call<num>('freeBytes', {'path': path}))?.toInt();
    }
    var dir = Directory(path);
    while (!dir.existsSync() && dir.parent.path != dir.path) {
      dir = dir.parent;
    }
    try {
      final r = await Process.run('df', ['-k', dir.path]);
      final lines = (r.stdout as String).trim().split('\n');
      if (lines.length < 2) return null;
      final cols = lines.last.trim().split(RegExp(r'\s+'));
      return int.parse(cols[3]) * 1024;
    } catch (_) {
      return null;
    }
  }

  static Future<void> reveal(String path) async {
    if (Platform.isMacOS) {
      await Process.run('open', ['-R', path]);
    } else if (Platform.isLinux) {
      final target = FileSystemEntity.isDirectorySync(path) ? path : p.dirname(path);
      await Process.run('xdg-open', [target]);
    }
  }
}

String formatBytes(num bytes) {
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var v = bytes.toDouble();
  var i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  return '${v.toStringAsFixed(i == 0 ? 0 : 1)} ${units[i]}';
}

/// A rough wait, said the way a person would: "≈25 MIN", "≈2.5 H".
String formatEstimate(Duration d) {
  final m = d.inSeconds / 60;
  if (m < 1) return '<1 MIN';
  if (m < 90) return '≈${m.round()} MIN';
  final h = (m / 30).round() / 2;
  return '≈${h == h.roundToDouble() ? h.toInt() : h} H';
}

String formatDuration(num seconds) {
  final s = seconds.round();
  final h = s ~/ 3600, m = (s % 3600) ~/ 60, r = s % 60;
  if (h > 0) return '$h:${m.toString().padLeft(2, '0')}:${r.toString().padLeft(2, '0')}';
  return '$m:${r.toString().padLeft(2, '0')}';
}
