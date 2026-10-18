import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../engine/engine.dart';
import '../engine/sidecar_engine.dart';
import '../engine/sidecar_process.dart';
import '../engine/sidecar_runtimes.dart';
import '../models/registry.dart';
import '../paths.dart';
import '../platform/android_bridge.dart';
import '../studio.dart';
import 'uv_bootstrap.dart';

/// Never leave less than this much free space after a download.
const int minFreeBytes = 2 * 1024 * 1024 * 1024;

/// What is missing before the selected model runs on the selected engine.
class SetupStatus {
  const SetupStatus({this.runtimeInstalled = true, this.missing = const [], this.needBytes = 0, this.freeBytes});

  final bool runtimeInstalled;

  /// Model files not present yet.
  final List<String> missing;
  final int needBytes;
  final int? freeBytes;

  bool get ready => runtimeInstalled && missing.isEmpty;
}

/// The one model setup flow: choose model and variant, accept its licence, install the engine
/// runtime if needed, download the weights. Shown on first run and reachable from Settings.
class ModelSetup extends ChangeNotifier {
  ModelSetup(this.studio) {
    if (Platform.isAndroid) _sub = AndroidBridge.events.where((e) => e['type'] == 'download').listen(_onDownload);
  }

  final Studio studio;
  StreamSubscription? _sub;
  final List<String> log = [];
  SetupStatus status = const SetupStatus(runtimeInstalled: false);
  String? task;
  String? error;
  double? progress;
  String progressText = '';
  Process? _proc;
  bool _cancel = false;
  Completer<void>? _androidDownload;

  bool get running => task != null;
  ModelSpec? get model => studio.model;
  ModelVariant? get variant => studio.variant;
  EngineDescriptor? get engine => studio.engineDescriptor;

  void _log(String s) {
    log.add(s);
    if (log.length > 3000) log.removeRange(0, log.length - 3000);
    notifyListeners();
  }

  // ------------------------------------------------------------------ status

  Future<SetupStatus> refresh() async {
    final m = model, f = studio.format, v = variant, e = engine;
    if (m == null || f == null || v == null || e == null) {
      status = const SetupStatus(runtimeInstalled: false);
      notifyListeners();
      return status;
    }
    if (Platform.isAndroid) {
      final dir = AppPaths.instance.modelDir(m.id, f.id);
      final files = await AndroidBridge.list('modelFiles', {'dir': dir, 'files': [for (final x in v.files) x.toJson()]});
      final missing = [for (final x in files) if (x['present'] != true) x['name'] as String];
      var need = 0;
      for (final x in files) {
        if (x['present'] != true) need += (x['bytes'] as num).toInt() - ((x['partBytes'] as num?)?.toInt() ?? 0);
      }
      status = SetupStatus(missing: missing, needBytes: need, freeBytes: await AppPaths.freeBytes(dir));
    } else {
      final rt = SidecarRuntime.of(e.runtime, studio.settings);
      final req = rt.requiredFiles(m, f, v);
      final missing = [for (final x in req.entries) if (!File(x.value).existsSync()) x.key];
      final need = missing.isEmpty
          ? 0
          : (f.kind == 'files'
              ? _missingBytes(rt, m, f, v)
              : (rt is MlxRuntime ? _snapshotNeedBytes(rt, m, f, v) : v.bytes));
      status = SetupStatus(
        runtimeInstalled: rt.installed,
        missing: missing,
        needBytes: need,
        freeBytes: await AppPaths.freeBytes(AppPaths.instance.dataDir),
      );
    }
    notifyListeners();
    return status;
  }

  int _missingBytes(SidecarRuntime rt, ModelSpec m, ModelFormat f, ModelVariant v) {
    final req = rt.requiredFiles(m, f, v);
    var sum = 0;
    for (final x in v.files) {
      final path = req[x.name];
      if (path == null || File(path).existsSync()) continue;
      final part = File('$path.part');
      sum += x.bytes - (part.existsSync() ? part.lengthSync() : 0);
    }
    return sum;
  }

  /// Estimate for an hf-snapshot: the full size minus what is already on disk (a 0.4.4 install
  /// being repaired keeps its files). Only verification left means nothing to download.
  int _snapshotNeedBytes(MlxRuntime rt, ModelSpec m, ModelFormat f, ModelVariant v) {
    var have = 0;
    final dirs = rt.ownsModelDir(m, f) ? [rt.modelRoot(m, f)] : [rt.modelDir(m, f), rt.vaeDir(m, f)];
    for (final d in dirs) {
      final dir = Directory(d);
      if (!dir.existsSync()) continue;
      for (final e in dir.listSync(recursive: true, followLinks: false)) {
        if (e is File && !e.path.contains('${p.separator}.cache${p.separator}')) have += e.lengthSync();
      }
    }
    return (v.bytes - have).clamp(0, v.bytes);
  }

  void acceptLicence() {
    final m = model;
    if (m == null) return;
    studio.settings.acceptLicence(m.id, m.licence.spdx);
    notifyListeners();
  }

  /// Finish the flow: remember it and start the engine.
  Future<void> complete() async {
    studio.settings.setupComplete = true;
    await studio.rebuildEngine();
    unawaited(studio.engine?.warmUp());
    notifyListeners();
  }

  // ------------------------------------------------------------------ install

  Future<void> cancel() async {
    _cancel = true;
    _proc?.kill();
    if (Platform.isAndroid) await AndroidBridge.call('cancelDownload');
  }

  /// Install whatever is missing for the current model, variant and engine.
  Future<void> install() => _guard('Setting up', () async {
        final m = model!, f = studio.format!, v = variant!, e = engine!;
        if (!studio.settings.licenceAccepted(m.id, m.licence.spdx)) {
          throw StateError('Accept the model licence first.');
        }
        if (Platform.isAndroid) {
          await _androidDownloadFiles(m, f, v);
          return;
        }
        final rt = SidecarRuntime.of(e.runtime, studio.settings);
        if (rt is MlxRuntime) {
          if (!rt.installed && !await _installMlx(rt, f)) return;
          if ((await refresh()).missing.isNotEmpty && !await _setupMlxModel(rt, m, f)) return;
        } else if (rt is Yue2CppRuntime) {
          if (!File(p.join(rt.binDir, 'yue-synth')).existsSync() && !await _buildYue2cpp(rt, f)) return;
          if (!File(rt.python()).existsSync() && !await _sidecarVenv()) return;
          if (!await _downloadFiles(rt.ggufDir(m, f), v.files)) return;
        }
        final live = studio.engine;
        if (live is SidecarEngine) await live.process.stop();
      });

  /// Use an existing runtime checkout (e.g. an mlx-Yue folder with its .venv and weights).
  Future<void> useExistingRuntime(String dir) async {
    final e = engine;
    if (e == null) return;
    studio.settings.setRuntime(e.runtime == 'mlx' ? 'mlx.dir' : 'yue2cpp.binDir', dir);
    final live = studio.engine;
    if (live is SidecarEngine) await live.process.stop();
    await refresh();
  }

  Future<void> _guard(String name, Future<void> Function() body) async {
    if (running) return;
    task = name;
    error = null;
    progress = null;
    _cancel = false;
    notifyListeners();
    try {
      await body();
    } catch (e) {
      error = e.toString();
      _log('ERROR: $e');
    } finally {
      task = null;
      progress = null;
      progressText = '';
      await refresh();
    }
  }

  // ------------------------------------------------------------------ desktop steps

  String? _uv;
  String? get _git => AppPaths.which('git');

  /// uv from the machine, or the app's own pinned copy (fetched once into the data dir).
  Future<bool> _ensureUv() async {
    if (_uv != null && File(_uv!).existsSync()) return true;
    try {
      _uv = await UvBootstrap(AppPaths.instance.dataDir).ensure(log: _log);
      return true;
    } catch (e) {
      error = '$e';
      _log(error!);
      return false;
    }
  }

  Future<bool> _run(String exe, List<String> args,
      {String? cwd, Map<String, String>? env, bool Function(String line)? onLine}) async {
    if (_cancel) return false;
    _log('\$ $exe ${args.join(' ')}${cwd != null ? '   (in $cwd)' : ''}');
    final proc = await Process.start(exe, args, workingDirectory: cwd, environment: env);
    _proc = proc;
    final done = Completer<void>();
    var open = 2;
    void closed() {
      if (--open == 0) done.complete();
    }

    proc.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
      if (onLine == null || !onLine(line)) _log(line);
    }, onDone: closed);
    proc.stderr.transform(utf8.decoder).transform(const LineSplitter()).listen(_log, onDone: closed);
    final code = await proc.exitCode;
    await done.future;
    _proc = null;
    if (code != 0) _log('exit code $code');
    return code == 0;
  }

  bool _tools() {
    if (_git == null) {
      error = Platform.isMacOS
          ? 'git not found. Run `xcode-select --install` in Terminal, then retry.'
          : 'git not found. Install git with your system package manager, then retry.';
      _log(error!);
      return false;
    }
    return true;
  }

  Future<bool> _checkDisk(int needBytes) async {
    final free = await AppPaths.freeBytes(AppPaths.instance.dataDir);
    if (free == null) return true;
    if (free - needBytes < minFreeBytes) {
      error = 'Not enough disk space: ${formatBytes(needBytes)} needed, ${formatBytes(free)} free.';
      _log(error!);
      return false;
    }
    return true;
  }

  Future<bool> _clone(String repo, String commit, String dir, {bool submodules = false}) async {
    if (Directory(p.join(dir, '.git')).existsSync()) {
      _log('Using existing checkout $dir');
      if (!await _run(_git!, ['fetch', '--quiet', 'origin'], cwd: dir)) return false;
    } else {
      await Directory(p.dirname(dir)).create(recursive: true);
      if (!await _run(_git!, ['clone', if (submodules) '--recurse-submodules', repo, dir])) return false;
    }
    if (!await _run(_git!, ['checkout', '--quiet', commit], cwd: dir)) return false;
    if (submodules && !await _run(_git!, ['submodule', 'update', '--init', '--recursive'], cwd: dir)) return false;
    return true;
  }

  Future<bool> _installMlx(MlxRuntime rt, ModelFormat f) async {
    if (!_tools() || !await _ensureUv()) return false;
    if (!await _checkDisk(2 * 1024 * 1024 * 1024)) return false;
    task = 'Installing ${f.runtime['name'] ?? 'the engine'}';
    notifyListeners();
    final dir = rt.engineDir;
    if (!await _clone(f.runtime['repo'] as String, f.runtime['commit'] as String, dir)) return false;
    return _run(_uv!, ['sync', '--frozen', '--no-dev'], cwd: dir, env: {'UV_PYTHON_PREFERENCE': 'managed'});
  }

  /// Lay out, repair, download and verify the mlx-Yue model folder (sidecar `mlx_setup`, run in the
  /// mlx-Yue venv). A 0.4.4 install (vae/ inside, a .cache tree, one AR precision) is fixed in place
  /// and only the missing files are fetched. Ends with mlx-Yue's own verify_conversion, so a bad
  /// folder shows up here instead of on Record.
  Future<bool> _setupMlxModel(MlxRuntime rt, ModelSpec m, ModelFormat f) async {
    task = 'Downloading ${m.name}';
    notifyListeners();
    final src = await SidecarProcess.extractSidecar();
    final userDir = studio.settings.runtime('mlx.modelDir').isNotEmpty;
    final args = userDir
        ? ['-m', 'studio_engine.mlx_setup', '--verify-only', '--model-dir', rt.modelDir(m, f), '--vae-dir', rt.vaeDir(m, f)]
        : [
            '-m', 'studio_engine.mlx_setup', '--repo', f.repo, '--revision', f.revision,
            '--root', rt.modelRoot(m, f), '--model-name', MlxRuntime.modelName(f),
          ];
    String? failure;
    final ok = await _run(rt.python(), args, cwd: rt.engineDir, env: {
      'PYTHONPATH': src,
      'PYTHONUNBUFFERED': '1',
      'PYTHONNOUSERSITE': '1',
      'MLX_ENABLE_TF32': '0',
    }, onLine: (line) {
      if (line.startsWith('@progress ')) {
        final e = jsonDecode(line.substring(10)) as Map<String, dynamic>;
        final done = (e['done'] as num).toInt(), total = (e['total'] as num).toInt();
        progress = total > 0 ? done / total : null;
        progressText = '${e['file']}: ${formatBytes(done)} of ${formatBytes(total)}';
        notifyListeners();
        return true;
      }
      if (line.startsWith('@result ')) {
        final r = jsonDecode(line.substring(8)) as Map<String, dynamic>;
        if (r['ok'] != true) failure = r['error'] as String?;
        return true;
      }
      if (line.startsWith('Checking the model folder')) {
        task = 'Verifying ${m.name}';
        progress = null;
        progressText = '';
        notifyListeners();
      }
      return false;
    });
    if (!ok) error = failure ?? 'Model setup failed. See the log.';
    return ok;
  }

  Future<bool> _sidecarVenv() async {
    if (!await _ensureUv()) return false;
    task = 'Creating the engine environment';
    notifyListeners();
    final src = await SidecarProcess.extractSidecar();
    return _run(_uv!, ['sync', '--frozen', '--no-dev', '--no-install-project', '--python', '3.12'],
        cwd: src, env: {'UV_PROJECT_ENVIRONMENT': AppPaths.instance.sidecarVenv});
  }

  static String buildScript() {
    if (Platform.isMacOS) return 'buildcpu.sh'; // Metal + Accelerate are enabled automatically
    if (AppPaths.which('nvcc', extra: ['/usr/local/cuda/bin']) != null) return 'buildcuda.sh';
    if (AppPaths.which('glslc') != null || File('/usr/include/vulkan/vulkan.h').existsSync()) return 'buildvulkan.sh';
    return 'buildcpu.sh';
  }

  Future<bool> _buildYue2cpp(Yue2CppRuntime rt, ModelFormat f) async {
    if (!_tools()) return false;
    if (AppPaths.which('cmake') == null) {
      error = 'cmake not found. Install cmake and a C++ compiler with your package manager.';
      _log(error!);
      return false;
    }
    if (!await _checkDisk(1024 * 1024 * 1024)) return false;
    task = 'Building ${f.runtime['name'] ?? 'the engine'}';
    notifyListeners();
    final dir = rt.checkoutDir;
    if (!await _clone(f.runtime['repo'] as String, f.runtime['commit'] as String, dir, submodules: true)) return false;
    _log('Build flavour: ${buildScript()}');
    return _run('bash', [buildScript()], cwd: dir);
  }

  /// Resumable, SHA-256 verified downloads (desktop).
  Future<bool> _downloadFiles(String dir, List<ModelFile> files) async {
    await Directory(dir).create(recursive: true);
    for (final f in files) {
      final out = File(p.join(dir, f.name));
      if (out.existsSync() && out.lengthSync() == f.bytes) continue;
      final part = File('${out.path}.part');
      final have = part.existsSync() ? part.lengthSync() : 0;
      if (!await _checkDisk(f.bytes - have)) return false;
      task = 'Downloading ${f.name}';
      notifyListeners();
      if (!await _download(f, part)) return false;
      progressText = 'Verifying ${f.name}';
      notifyListeners();
      final digest = await sha256.bind(part.openRead()).first;
      if (digest.toString() != f.sha256) {
        await part.delete();
        error = '${f.name}: checksum mismatch; the partial file was deleted. Try again.';
        _log(error!);
        return false;
      }
      await part.rename(out.path);
      _log('${f.name}: OK');
    }
    return true;
  }

  Future<bool> _download(ModelFile f, File part) async {
    final client = HttpClient();
    try {
      var have = part.existsSync() ? part.lengthSync() : 0;
      final req = await client.getUrl(Uri.parse(f.url));
      if (have > 0) req.headers.set(HttpHeaders.rangeHeader, 'bytes=$have-');
      final res = await req.close();
      if (res.statusCode == 200) {
        have = 0;
      } else if (res.statusCode != 206) {
        error = '${f.name}: HTTP ${res.statusCode}';
        _log(error!);
        return false;
      }
      final sink = part.openWrite(mode: have > 0 ? FileMode.append : FileMode.write);
      var got = have;
      var last = DateTime.now();
      await for (final chunk in res) {
        if (_cancel) {
          await sink.close();
          _log('Paused; the download resumes where it stopped.');
          return false;
        }
        sink.add(chunk);
        got += chunk.length;
        progress = got / f.bytes;
        if (DateTime.now().difference(last).inMilliseconds > 500) {
          last = DateTime.now();
          progressText = '${f.name}: ${formatBytes(got)} of ${formatBytes(f.bytes)}';
          notifyListeners();
        }
      }
      await sink.close();
      return true;
    } catch (e) {
      error = '${f.name}: $e';
      _log(error!);
      return false;
    } finally {
      client.close(force: true);
    }
  }

  // ------------------------------------------------------------------ Android

  Future<void> _androidDownloadFiles(ModelSpec m, ModelFormat f, ModelVariant v) async {
    await AndroidBridge.call('requestNotifications');
    final dir = AppPaths.instance.modelDir(m.id, f.id);
    _androidDownload = Completer<void>();
    task = 'Downloading ${m.name} (${v.name})';
    notifyListeners();
    await AndroidBridge.call('download', {'dir': dir, 'files': [for (final x in v.files) x.toJson()]});
    await _androidDownload!.future;
  }

  void _onDownload(Map<String, dynamic> e) {
    if (e['active'] == true) {
      task ??= 'Downloading';
      final total = (e['total'] as num?)?.toInt() ?? 0;
      final done = (e['done'] as num?)?.toInt() ?? 0;
      progress = total > 0 ? done / total : null;
      final rate = (e['rate'] as num?)?.toInt() ?? 0;
      progressText = '${e['phase']} ${e['file']}: ${formatBytes(done)} of ${formatBytes(total)}'
          '${rate > 0 ? ' · ${formatBytes(rate)}/s' : ''}';
      notifyListeners();
      return;
    }
    if (e['error'] != null) {
      error = e['error'] as String;
      _log(error!);
    } else if (e['message'] != null) {
      _log(e['message'] as String);
    }
    final c = _androidDownload;
    _androidDownload = null;
    if (c != null && !c.isCompleted) c.complete();
    notifyListeners();
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}
