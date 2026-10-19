import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'paths.dart';

/// Persistent settings: JSON in the app data dir. Machine-specific paths live only here
/// (or come from auto-detection), never in the source.
class Settings extends ChangeNotifier {
  Settings(this._file);

  final String _file;
  Map<String, dynamic> _data = {};

  static Future<Settings> load(AppPaths paths) async {
    final s = Settings(paths.settingsFile);
    final f = File(paths.settingsFile);
    final fresh = !f.existsSync();
    try {
      if (!fresh) s._data = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
    } catch (_) {}
    if (fresh && !Platform.isAndroid) {
      // Songs made by the earlier desktop app (YuE2 Studio 0.1) show up read-only.
      final legacy = Platform.isMacOS
          ? p.join(AppPaths.home, 'Library', 'Application Support', 'YuE2 Studio', 'library')
          : p.join(AppPaths.home, '.local', 'share', 'yue2-studio', 'library');
      if (Directory(legacy).existsSync()) s._data['importRoots'] = [legacy];
    }
    await s.save();
    return s;
  }

  Future<void> _saving = Future.value();

  /// Writes are serialised so overlapping saves never race on the temp file.
  Future<void> save() => _saving = _saving.then((_) async {
        final f = File(_file);
        await f.parent.create(recursive: true);
        final tmp = File('$_file.tmp');
        await tmp.writeAsString(const JsonEncoder.withIndent('  ').convert(_data));
        await tmp.rename(_file);
      }).catchError((_) {});

  T _get<T>(String key, T fallback) {
    final v = _data[key];
    return v is T ? v : fallback;
  }

  String str(String key) => _get(key, '');

  void set(String key, Object? value) {
    if (value == null || (value is String && value.isEmpty)) {
      _data.remove(key);
    } else {
      _data[key] = value;
    }
    save();
    notifyListeners();
  }

  // ---------------------------------------------------------------- engine and model

  /// '' = choose by hardware.
  String get engineOverride => _get('engine', '');
  set engineOverride(String v) => set('engine', v);

  String get activeModel => _get('activeModel', '');
  set activeModel(String v) => set('activeModel', v);

  String? variantFor(String modelId, String formatId) => (_get<Map>('variants', const {}))['$modelId/$formatId'] as String?;
  void setVariant(String modelId, String formatId, String variantId) {
    final m = Map<String, dynamic>.from(_get<Map>('variants', const {}));
    m['$modelId/$formatId'] = variantId;
    set('variants', m);
  }

  /// Licences the user accepted: [{model, licence, accepted}]
  List<Map<String, dynamic>> get acceptedLicences =>
      [for (final e in _get<List>('acceptedLicences', const [])) Map<String, dynamic>.from(e as Map)];

  bool licenceAccepted(String modelId, String spdx) =>
      acceptedLicences.any((e) => e['model'] == modelId && e['licence'] == spdx);

  void acceptLicence(String modelId, String spdx) {
    if (licenceAccepted(modelId, spdx)) return;
    set('acceptedLicences', [
      ...acceptedLicences,
      {'model': modelId, 'licence': spdx, 'accepted': DateTime.now().toIso8601String()},
    ]);
  }

  /// Set when the first-run setup finished (the setup flow stays reachable from Settings).
  /// Quality presets were introduced: slow devices were moved to the sketch preset once.
  bool get presetsIntroduced => _get('sketchDefaultApplied', false);
  set presetsIntroduced(bool v) => set('sketchDefaultApplied', v);

  bool get setupComplete => _get('setupComplete', false);
  set setupComplete(bool v) => set('setupComplete', v);

  /// Per-runtime overrides, e.g. runtime.mlx.dir, runtime.yue2cpp.binDir, runtime.yue2cpp.device.
  String runtime(String key) => _get('runtime.$key', '');
  void setRuntime(String key, String value) => set('runtime.$key', value);

  String get sidecarPythonOverride => _get('sidecarPython', '');

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

  // Last form values, so the Generate screen survives restarts.
  Map<String, dynamic> get lastForm => Map<String, dynamic>.from(_get<Map>('lastForm', const {}));
  set lastForm(Map<String, dynamic> v) {
    _data['lastForm'] = v;
    save();
  }
}
