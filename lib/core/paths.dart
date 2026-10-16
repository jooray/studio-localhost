import 'dart:io';

import 'package:path/path.dart' as p;

/// Platform locations. macOS: ~/Library/Application Support/YuE2 Studio,
/// Linux: $XDG_DATA_HOME/yue2-studio (default ~/.local/share/yue2-studio).
class AppPaths {
  AppPaths._(this.dataDir);

  final String dataDir;

  static late AppPaths instance;

  static String get home => Platform.environment['HOME'] ?? '/';

  static AppPaths init() {
    String dir;
    if (Platform.isMacOS) {
      dir = p.join(home, 'Library', 'Application Support', 'YuE2 Studio');
    } else {
      final xdg = Platform.environment['XDG_DATA_HOME'];
      dir = p.join((xdg != null && xdg.isNotEmpty) ? xdg : p.join(home, '.local', 'share'), 'yue2-studio');
    }
    Directory(dir).createSync(recursive: true);
    instance = AppPaths._(dir);
    return instance;
  }

  String get settingsFile => p.join(dataDir, 'settings.json');
  String get libraryDir => p.join(dataDir, 'library');
  String get sidecarDir => p.join(dataDir, 'sidecar');
  String get sidecarVenv => p.join(dataDir, 'sidecar-venv');
  String get engineDir => p.join(dataDir, 'engine');
  String get mlxEngineDir => p.join(engineDir, 'mlx-Yue');
  String get yue2cppDir => p.join(engineDir, 'yue2.cpp');
  String get ggufDir => p.join(dataDir, 'models', 'gguf');
  String get logsDir => p.join(dataDir, 'logs');

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

  /// Free bytes on the volume holding [path] (via `df -k`, works on macOS and Linux).
  static Future<int?> freeBytes(String path) async {
    var dir = Directory(path);
    while (!dir.existsSync() && dir.parent.path != dir.path) {
      dir = dir.parent;
    }
    try {
      final r = await Process.run('df', ['-k', dir.path]);
      final lines = (r.stdout as String).trim().split('\n');
      if (lines.length < 2) return null;
      final cols = lines.last.trim().split(RegExp(r'\s+'));
      // Filesystem 1024-blocks Used Available ...
      return int.parse(cols[3]) * 1024;
    } catch (_) {
      return null;
    }
  }

  static Future<void> reveal(String path) async {
    if (Platform.isMacOS) {
      await Process.run('open', ['-R', path]);
    } else {
      final target = FileSystemEntity.isDirectorySync(path) ? path : p.dirname(path);
      await Process.run('xdg-open', [target]);
    }
  }

  static Future<void> openPath(String path) async {
    await Process.run(Platform.isMacOS ? 'open' : 'xdg-open', [path]);
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

String formatDuration(num seconds) {
  final s = seconds.round();
  final h = s ~/ 3600, m = (s % 3600) ~/ 60, r = s % 60;
  if (h > 0) return '$h:${m.toString().padLeft(2, '0')}:${r.toString().padLeft(2, '0')}';
  return '$m:${r.toString().padLeft(2, '0')}';
}
