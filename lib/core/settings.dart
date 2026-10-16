import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'paths.dart';

/// Persistent settings (JSON in the app data dir).
class Settings extends ChangeNotifier {
  Settings(this._file);

  final String _file;
  Map<String, dynamic> _data = {};

  static const _knownMlxEngine = '/Users/juraj/tmp/yue2/mlx-Yue';
  static const _knownOutputs = '/Users/juraj/tmp/yue2/outputs';

  static Future<Settings> load(AppPaths paths) async {
    final s = Settings(paths.settingsFile);
    try {
      final f = File(paths.settingsFile);
      if (f.existsSync()) s._data = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
    } catch (_) {}
    if (!s._data.containsKey('importRoots')) {
      s._data['importRoots'] = [if (Directory(_knownOutputs).existsSync()) _knownOutputs];
    }
    await s.save();
    return s;
  }

  Future<void> save() async {
    final f = File(_file);
    await f.parent.create(recursive: true);
    final tmp = File('$_file.tmp');
    await tmp.writeAsString(const JsonEncoder.withIndent('  ').convert(_data));
    await tmp.rename(_file);
  }

  T _get<T>(String key, T fallback) {
    final v = _data[key];
    return v is T ? v : fallback;
  }

  void set(String key, Object? value) {
    if (value == null) {
      _data.remove(key);
    } else {
      _data[key] = value;
    }
    save();
    notifyListeners();
  }

  // ---------------------------------------------------------------- backend

  static String get platformDefaultBackend {
    if (Platform.isMacOS) {
      // mlx only runs on Apple Silicon; Intel Macs fall back to yue2.cpp.
      final arch = Process.runSync('uname', ['-m']).stdout.toString().trim();
      return arch == 'arm64' ? 'mlx' : 'yue2cpp';
    }
    return 'yue2cpp';
  }

  /// '' = automatic by platform.
  String get backendOverride => _get('backend', '');
  String get backend => backendOverride.isEmpty ? platformDefaultBackend : backendOverride;

  // mlx
  String get mlxEngineDir {
    final v = _get('mlxEngineDir', '');
    if (v.isNotEmpty) return v;
    if (Directory(_knownMlxEngine).existsSync()) return _knownMlxEngine;
    return AppPaths.instance.mlxEngineDir;
  }

  String get mlxModelDir {
    final v = _get('mlxModelDir', '');
    return v.isNotEmpty ? v : p.join(mlxEngineDir, 'models', 'mlx-Yue2-3B');
  }

  String get mlxVaeDir {
    final v = _get('mlxVaeDir', '');
    if (v.isNotEmpty) return v;
    final plain = p.join(mlxEngineDir, 'models', 'vae');
    final bundled = p.join(mlxModelDir, 'vae');
    return !Directory(plain).existsSync() && Directory(bundled).existsSync() ? bundled : plain;
  }

  String get mlxPython => AppPaths.venvPython(p.join(mlxEngineDir, '.venv'));

  // yue2.cpp
  String get yue2cppBinDir {
    final v = _get('yue2cppBinDir', '');
    return v.isNotEmpty ? v : p.join(AppPaths.instance.yue2cppDir, 'build');
  }

  String get ggufQuant => _get('ggufQuant', 'Q8_0');
  String get ggufModel {
    final v = _get('ggufModel', '');
    return v.isNotEmpty ? v : p.join(AppPaths.instance.ggufDir, 'YuE2-3B-$ggufQuant.gguf');
  }

  String get ggufVae {
    final v = _get('ggufVae', '');
    return v.isNotEmpty ? v : p.join(AppPaths.instance.ggufDir, 'YuE2-Vae-F32.gguf');
  }

  String get yue2cppDevice => _get('yue2cppDevice', '');

  // torch (stub)
  String get torchPython => _get('torchPython', '');

  /// Python that runs the sidecar for the active backend.
  String get sidecarPython {
    final override = _get('sidecarPython', '');
    if (override.isNotEmpty) return override;
    switch (backend) {
      case 'mlx':
        return mlxPython;
      case 'torch':
        if (torchPython.isNotEmpty) return torchPython;
        break;
    }
    final own = AppPaths.venvPython(AppPaths.instance.sidecarVenv);
    if (File(own).existsSync()) return own;
    // On a Mac with the mlx engine installed, its venv has numpy+soundfile too.
    if (File(mlxPython).existsSync()) return mlxPython;
    return own;
  }

  String get sidecarPythonOverride => _get('sidecarPython', '');

  Map<String, dynamic> backendConfig() {
    switch (backend) {
      case 'mlx':
        return {
          'backend': 'mlx',
          'engine_dir': mlxEngineDir,
          'model_dir': mlxModelDir,
          'vae_dir': mlxVaeDir,
        };
      case 'yue2cpp':
        return {
          'backend': 'yue2cpp',
          'yue2cpp_bin_dir': yue2cppBinDir,
          'gguf_model': ggufModel,
          'gguf_vae': ggufVae,
          if (yue2cppDevice.isNotEmpty) 'device': yue2cppDevice,
        };
      default:
        return {'backend': backend};
    }
  }

  // ---------------------------------------------------------------- library

  List<String> get importRoots => List<String>.from(_get<List>('importRoots', const []));
  set importRoots(List<String> v) => set('importRoots', v);

  List<String> get hiddenSongs => List<String>.from(_get<List>('hiddenSongs', const []));
  void hideSong(String dir) => set('hiddenSongs', {...hiddenSongs, dir}.toList());

  String get ffmpegPath => _get('ffmpegPath', '');

  // ---------------------------------------------------------------- update check

  String get updateUrl => _get('updateUrl', '');
  bool get updateCheckOn => _get('updateCheck', false);
  bool get updateCheckEnabled => updateCheckOn && updateUrl.isNotEmpty;

  // ---------------------------------------------------------------- calibration for ETA

  double calib(String key, double fallback) {
    final m = _get<Map>('calibration', const {});
    final v = m[key];
    return v is num ? v.toDouble() : fallback;
  }

  void setCalib(String key, double value) {
    final m = Map<String, dynamic>.from(_get<Map>('calibration', const {}));
    final old = m[key];
    m[key] = old is num ? (old * 0.5 + value * 0.5) : value;
    _data['calibration'] = m;
    save();
  }

  // Last form values, so the Generate page survives restarts.
  Map<String, dynamic> get lastForm => Map<String, dynamic>.from(_get<Map>('lastForm', const {}));
  set lastForm(Map<String, dynamic> v) {
    _data['lastForm'] = v;
    save();
  }

  String raw(String key) => _get(key, '');
}
