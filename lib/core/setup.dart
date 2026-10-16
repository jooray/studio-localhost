import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'paths.dart';
import 'settings.dart';
import 'sidecar.dart';
import 'version.dart';

class GgufFile {
  const GgufFile(this.name, this.size, this.sha256);
  final String name;
  final int size;
  final String sha256;
  String get url => 'https://huggingface.co/$ggufRepo/resolve/main/$name?download=true';
}

const ggufCatalog = <String, GgufFile>{
  'Q6_K': GgufFile('YuE2-3B-Q6_K.gguf', 2943331072, '42068d5e57713df11b9f6a5a3751072d9bbefe231d1d088f9c100e026ffa4ef9'),
  'Q8_0': GgufFile('YuE2-3B-Q8_0.gguf', 3810232064, '41121ce97786d7795a325bcf123ca196956c03bb252c9e75384cfc1f2fc19e6b'),
  'VAE': GgufFile('YuE2-Vae-F32.gguf', 530497344, '93e49dfb1970e89ad64cacb17cf13b5d05f6bb30ef7ed3adae3050bcb728638a'),
};

/// Never leave less than this much free space after a download.
const int minFreeBytes = 6 * 1024 * 1024 * 1024;

/// "Set up engine": everything goes under the app data dir, Python only in uv-managed venvs.
class EngineSetup extends ChangeNotifier {
  EngineSetup(this.settings, this.sidecar);

  final Settings settings;
  final Sidecar sidecar;
  final List<String> log = [];
  String? task;
  double? progress;
  Process? _proc;
  bool _cancel = false;

  bool get running => task != null;

  void _log(String s) {
    log.add(s);
    if (log.length > 3000) log.removeRange(0, log.length - 3000);
    notifyListeners();
  }

  String? get uv => AppPaths.which('uv');
  String? get git => AppPaths.which('git');

  Future<void> cancel() async {
    _cancel = true;
    _proc?.kill();
  }

  Future<bool> _run(String exe, List<String> args, {String? cwd, Map<String, String>? env}) async {
    if (_cancel) return false;
    _log('\$ $exe ${args.join(' ')}${cwd != null ? '   (in $cwd)' : ''}');
    final proc = await Process.start(exe, args, workingDirectory: cwd, environment: env);
    _proc = proc;
    final done = Completer<void>();
    var open = 2;
    void closed() {
      if (--open == 0) done.complete();
    }

    proc.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen(_log, onDone: closed);
    proc.stderr.transform(utf8.decoder).transform(const LineSplitter()).listen(_log, onDone: closed);
    final code = await proc.exitCode;
    await done.future;
    _proc = null;
    if (code != 0) _log('exit code $code');
    return code == 0;
  }

  Future<void> _guard(String name, Future<void> Function() body) async {
    if (running) return;
    task = name;
    progress = null;
    _cancel = false;
    log.clear();
    notifyListeners();
    try {
      await body();
    } catch (e) {
      _log('ERROR: $e');
    } finally {
      task = null;
      progress = null;
      notifyListeners();
    }
  }

  Future<bool> _requireTools() async {
    if (git == null) {
      _log('git not found. Install git with your system package manager, then retry.');
      return false;
    }
    if (uv == null) {
      _log('uv not found. Install it (https://docs.astral.sh/uv/getting-started/installation/), '
          'e.g. `curl -LsSf https://astral.sh/uv/install.sh | sh` (installs into ~/.local/bin, not system-wide).');
      return false;
    }
    return true;
  }

  Future<bool> _checkDisk(int needBytes) async {
    final free = await AppPaths.freeBytes(AppPaths.instance.dataDir);
    if (free == null) return true;
    _log('Free disk: ${formatBytes(free)}; this step needs about ${formatBytes(needBytes)} '
        '(keeping ${formatBytes(minFreeBytes)} free).');
    if (free - needBytes < minFreeBytes) {
      _log('Not enough disk space. Free some space first.');
      return false;
    }
    return true;
  }

  Future<bool> _clone(String repo, String commit, String dir, {bool submodules = false}) async {
    if (Directory(p.join(dir, '.git')).existsSync()) {
      _log('Using existing checkout $dir');
      if (!await _run(git!, ['fetch', '--quiet', 'origin'], cwd: dir)) return false;
    } else {
      await Directory(p.dirname(dir)).create(recursive: true);
      if (!await _run(git!, ['clone', if (submodules) '--recurse-submodules', repo, dir])) return false;
    }
    if (!await _run(git!, ['checkout', '--quiet', commit], cwd: dir)) return false;
    if (submodules && !await _run(git!, ['submodule', 'update', '--init', '--recursive'], cwd: dir)) return false;
    return true;
  }

  /// mlx backend: clone mlx-Yue at the pinned commit and `uv sync --frozen --no-dev`.
  Future<void> setupMlx({bool downloadWeights = false, String precision = '8bit'}) => _guard('Set up mlx engine', () async {
        if (!await _requireTools()) return;
        if (!await _checkDisk(2 * 1024 * 1024 * 1024)) return;
        final dir = AppPaths.instance.mlxEngineDir;
        if (!await _clone(mlxYueRepo, mlxYueCommit, dir)) return;
        if (!await _run(uv!, ['sync', '--frozen', '--no-dev'], cwd: dir, env: {'UV_PYTHON_PREFERENCE': 'managed'})) return;
        settings.set('mlxEngineDir', dir);
        _log('mlx engine ready at $dir');
        if (downloadWeights) {
          // AR at the chosen precision + NAR + VAE (about 9 GB with both AR precisions).
          final need = (precision == 'bf16' ? 4.4 : 2.7) * 1e9 + 4.5e9 + 0.6e9;
          if (!await _checkDisk(need.round())) return;
          final py = AppPaths.venvPython(p.join(dir, '.venv'));
          final script = 'from huggingface_hub import snapshot_download\n'
              'snapshot_download(repo_id="$mlxWeightsRepo", local_dir="models/mlx-Yue2-3B", '
              'allow_patterns=["*.json","*.md","*.tiktoken","LICENSE","licenses/*","vae/*",'
              '"ar-$precision.safetensors","nar-bf16.safetensors"])\n';
          if (!await _run(py, ['-c', script], cwd: dir)) return;
          if (Directory(p.join(dir, 'models', 'mlx-Yue2-3B', 'vae')).existsSync() &&
              !Directory(p.join(dir, 'models', 'vae')).existsSync()) {
            settings.set('mlxVaeDir', p.join(dir, 'models', 'mlx-Yue2-3B', 'vae'));
          }
          _log('Weights downloaded.');
        }
        await sidecar.stop();
      });

  /// Sidecar-only venv (numpy + soundfile) for the yue2cpp backend.
  Future<void> setupSidecarVenv() => _guard('Create sidecar venv', () async {
        if (uv == null) {
          await _requireTools();
          return;
        }
        final src = await Sidecar.extractSidecar();
        if (!await _run(uv!, ['sync', '--frozen', '--no-dev', '--no-install-project'],
            cwd: src, env: {'UV_PROJECT_ENVIRONMENT': AppPaths.instance.sidecarVenv})) {
          return;
        }
        _log('Sidecar venv ready: ${AppPaths.instance.sidecarVenv}');
        await sidecar.stop();
      });

  /// yue2cpp backend: clone at the pinned commit and build (CUDA > Vulkan > CPU on Linux, Metal on macOS).
  Future<void> setupYue2cpp() => _guard('Build yue2.cpp', () async {
        if (git == null) {
          await _requireTools();
          return;
        }
        if (AppPaths.which('cmake') == null) {
          _log('cmake not found. Install cmake and a C++ compiler with your package manager.');
          return;
        }
        if (!await _checkDisk(1024 * 1024 * 1024)) return;
        final dir = AppPaths.instance.yue2cppDir;
        if (!await _clone(yue2cppRepo, yue2cppCommit, dir, submodules: true)) return;
        final script = buildScript();
        _log('Build flavour: $script');
        if (!await _run('bash', [script], cwd: dir)) return;
        settings.set('yue2cppBinDir', p.join(dir, 'build'));
        _log('yue2.cpp built: ${p.join(dir, 'build')}');
        await sidecar.stop();
      });

  static String buildScript() {
    if (Platform.isMacOS) return 'buildcpu.sh'; // Metal + Accelerate are enabled automatically
    final nvcc = AppPaths.which('nvcc', extra: ['/usr/local/cuda/bin']);
    if (nvcc != null) return 'buildcuda.sh';
    if (AppPaths.which('glslc') != null || File('/usr/include/vulkan/vulkan.h').existsSync()) return 'buildvulkan.sh';
    return 'buildcpu.sh';
  }

  /// Download (resumable, SHA-256 verified) the backbone quant and the VAE GGUF.
  Future<void> downloadGguf(String quant) => _guard('Download GGUF weights', () async {
        final files = [ggufCatalog[quant]!, ggufCatalog['VAE']!];
        final dir = AppPaths.instance.ggufDir;
        await Directory(dir).create(recursive: true);
        for (final f in files) {
          final out = File(p.join(dir, f.name));
          if (out.existsSync() && out.lengthSync() == f.size) {
            _log('${f.name}: present');
            continue;
          }
          final part = File('${out.path}.part');
          final have = part.existsSync() ? part.lengthSync() : 0;
          if (!await _checkDisk(f.size - have)) return;
          if (!await _download(f, part)) return;
          _log('${f.name}: verifying SHA-256…');
          final digest = await sha256.bind(part.openRead()).first;
          if (digest.toString() != f.sha256) {
            _log('${f.name}: checksum mismatch, deleting the partial file');
            await part.delete();
            return;
          }
          await part.rename(out.path);
          _log('${f.name}: OK');
        }
        settings.set('ggufQuant', quant);
        await sidecar.stop();
      });

  Future<bool> _download(GgufFile f, File part) async {
    final client = HttpClient();
    try {
      var have = part.existsSync() ? part.lengthSync() : 0;
      final req = await client.getUrl(Uri.parse(f.url));
      if (have > 0) req.headers.set(HttpHeaders.rangeHeader, 'bytes=$have-');
      final res = await req.close();
      if (res.statusCode == 200) {
        have = 0;
      } else if (res.statusCode != 206) {
        _log('${f.name}: HTTP ${res.statusCode}');
        return false;
      }
      final sink = part.openWrite(mode: have > 0 ? FileMode.append : FileMode.write);
      var got = have;
      var lastLog = DateTime.now();
      await for (final chunk in res) {
        if (_cancel) {
          await sink.close();
          _log('Paused; the download resumes where it stopped.');
          return false;
        }
        sink.add(chunk);
        got += chunk.length;
        progress = got / f.size;
        if (DateTime.now().difference(lastLog).inSeconds >= 2) {
          lastLog = DateTime.now();
          _log('${f.name}: ${formatBytes(got)} / ${formatBytes(f.size)}');
        }
      }
      await sink.close();
      return true;
    } catch (e) {
      _log('${f.name}: $e');
      return false;
    } finally {
      client.close(force: true);
    }
  }
}
