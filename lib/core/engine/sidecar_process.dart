import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../paths.dart';

enum SidecarState { stopped, starting, ready, failed }

/// How to launch the sidecar: which Python and where.
class SidecarLaunch {
  const SidecarLaunch({required this.python, required this.cwd, required this.config});
  final String python;
  final String cwd;

  /// Sent with `configure` once the process is up.
  final Map<String, dynamic> config;
}

/// The Python engine sidecar (package studio_engine), spoken to in JSON lines over stdio.
class SidecarProcess extends ChangeNotifier {
  SidecarProcess(this.launch);

  /// Re-evaluated on every start, so settings changes apply after a restart.
  final SidecarLaunch Function() launch;
  Process? _proc;
  SidecarState state = SidecarState.stopped;
  String? error;
  Map<String, dynamic>? hello;
  Map<String, dynamic>? info;
  String? configuredBackend;
  final List<String> log = [];
  final _events = StreamController<Map<String, dynamic>>.broadcast();
  final Map<String, Completer<Map<String, dynamic>>> _pending = {};
  int _seq = 0;
  Future<void>? _starting;

  Stream<Map<String, dynamic>> get events => _events.stream;
  bool get isReady => state == SidecarState.ready;

  void _log(String line) {
    log.add(line);
    if (log.length > 2000) log.removeRange(0, log.length - 2000);
  }

  /// Copy the bundled sidecar package out of the Flutter assets so Python can import it.
  static Future<String> extractSidecar() async {
    final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
    final assets = manifest.listAssets().where((a) => a.startsWith('sidecar/')).toList();
    final root = AppPaths.instance.sidecarDir;
    for (final a in assets) {
      final data = await rootBundle.load(a);
      final out = File(p.join(root, a.substring('sidecar/'.length)));
      await out.parent.create(recursive: true);
      await out.writeAsBytes(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes), flush: true);
    }
    return root;
  }

  Future<void> ensureStarted() {
    if (state == SidecarState.ready) return Future.value();
    return _starting ??= _start().whenComplete(() => _starting = null);
  }

  Future<void> _start() async {
    state = SidecarState.starting;
    error = null;
    notifyListeners();
    try {
      final src = await extractSidecar();
      final l = launch();
      final python = l.python;
      if (!File(python).existsSync()) {
        throw StateError('Python not found: $python\nRun the model setup (Settings > Model and engine).');
      }
      final cwd = Directory(l.cwd).existsSync() ? l.cwd : AppPaths.instance.dataDir;
      final env = {
        'PYTHONPATH': src,
        'PYTHONUNBUFFERED': '1',
        'MLX_ENABLE_TF32': '0',
        'PYTHONNOUSERSITE': '1',
        // A GUI launch does not see Homebrew or ~/.local/bin; the engine and the tools it runs
        // (ffmpeg for cover listening) need them.
        'PATH': AppPaths.childPath,
      };
      _log('\$ $python -m studio_engine   (cwd $cwd)');
      final proc = await Process.start(python, ['-m', 'studio_engine'], workingDirectory: cwd, environment: env);
      _proc = proc;
      final ready = Completer<void>();
      proc.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
        Map<String, dynamic> msg;
        try {
          msg = jsonDecode(line) as Map<String, dynamic>;
        } catch (_) {
          _log(line);
          return;
        }
        if (msg['event'] == 'ready') {
          hello = msg;
          if (!ready.isCompleted) ready.complete();
          return;
        }
        final id = msg['id'];
        if (id != null && _pending.containsKey(id)) {
          final c = _pending.remove(id)!;
          if (msg['ok'] == true) {
            c.complete(Map<String, dynamic>.from(msg['result'] as Map? ?? {}));
          } else {
            c.completeError(SidecarError(msg['error']?.toString() ?? 'error'));
          }
          return;
        }
        if (msg['event'] == 'log') _log(msg['line']?.toString() ?? '');
        if (msg.containsKey('event')) _events.add(msg);
      });
      proc.stderr.transform(utf8.decoder).transform(const LineSplitter()).listen(_log);
      proc.exitCode.then((code) {
        _log('sidecar exited with $code');
        if (_proc == proc) {
          _proc = null;
          configuredBackend = null;
          state = code == 0 ? SidecarState.stopped : SidecarState.failed;
          error ??= code == 0 ? null : 'Engine process exited with code $code. See the engine log.';
          for (final c in _pending.values) {
            c.completeError(SidecarError('engine exited'));
          }
          _pending.clear();
          _events.add({'event': 'sidecar_exit', 'code': code});
          notifyListeners();
        }
        if (!ready.isCompleted) ready.completeError(StateError('Engine exited with $code:\n${log.reversed.take(12).toList().reversed.join('\n')}'));
      });
      await ready.future.timeout(const Duration(seconds: 60));
      state = SidecarState.ready;
      notifyListeners();
      await configure();
    } catch (e) {
      state = SidecarState.failed;
      error = e.toString();
      _proc?.kill();
      _proc = null;
      notifyListeners();
      rethrow;
    }
  }

  Future<void> configure() async {
    final cfg = launch().config;
    await request('configure', cfg);
    configuredBackend = jsonEncode(cfg);
    notifyListeners();
  }

  /// Reconfigure when the settings produce a different backend configuration.
  Future<void> ensureConfigured() async {
    await ensureStarted();
    if (configuredBackend != jsonEncode(launch().config)) await configure();
  }

  Future<Map<String, dynamic>> request(String cmd, [Map<String, dynamic> args = const {}]) {
    final proc = _proc;
    if (proc == null) return Future.error(SidecarError('engine not running'));
    final id = 'r${++_seq}';
    final c = Completer<Map<String, dynamic>>();
    _pending[id] = c;
    proc.stdin.writeln(jsonEncode({'id': id, 'cmd': cmd, ...args}));
    return c.future;
  }

  Future<Map<String, dynamic>> refreshInfo() async {
    await ensureStarted();
    info = await request('info');
    notifyListeners();
    return info!;
  }

  Future<void> restart() async {
    await stop();
    await ensureStarted();
  }

  Future<void> stop() async {
    final proc = _proc;
    if (proc == null) return;
    try {
      await request('shutdown').timeout(const Duration(seconds: 3));
    } catch (_) {}
    await proc.exitCode.timeout(const Duration(seconds: 5), onTimeout: () {
      proc.kill(ProcessSignal.sigkill);
      return -9;
    });
    _proc = null;
    state = SidecarState.stopped;
    configuredBackend = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _proc?.kill();
    _events.close();
    super.dispose();
  }
}

class SidecarError implements Exception {
  SidecarError(this.message);
  final String message;
  @override
  String toString() => message;
}
