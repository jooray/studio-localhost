import 'dart:async';

import '../library/song.dart';
import '../settings.dart';
import 'engine.dart';
import 'sidecar_process.dart';
import 'sidecar_runtimes.dart';

/// Desktop engine: the Python sidecar over JSON lines, with a runtime adapter (mlx or yue2cpp).
/// One job at a time; the app's JobQueue feeds it.
class SidecarEngine extends Engine {
  SidecarEngine(this.descriptor, this.settings, {required this.defaultContext})
      : runtime = SidecarRuntime.of(descriptor.runtime, settings) {
    process = SidecarProcess(() {
      final c = _current ?? defaultContext();
      return SidecarLaunch(python: runtime.python(), cwd: runtime.cwd(), config: runtime.config(c.model, c.format, c.variant));
    });
    process.addListener(notifyListeners);
    _sub = process.events.listen(_onEvent);
  }

  @override
  final EngineDescriptor descriptor;
  final Settings settings;
  final SidecarRuntime runtime;
  /// The current model/variant selection, used until a job brings its own context.
  final JobContext Function() defaultContext;
  late final SidecarProcess process;
  late final StreamSubscription _sub;
  final _events = StreamController<EngineEvent>.broadcast();
  String? _running;
  JobContext? _current;
  Map<String, dynamic>? _info;

  @override
  Stream<EngineEvent> get events => _events.stream;

  @override
  bool get ownsQueue => false;

  @override
  bool get writesSongMetadata => false;

  @override
  bool get busy => _running != null;

  @override
  String get statusText => switch (process.state) {
        SidecarState.ready => 'Ready',
        SidecarState.starting => 'Starting',
        SidecarState.failed => process.error ?? 'Failed',
        SidecarState.stopped => 'Stopped',
      };

  @override
  bool get canTokenizeAudio => (_info?['capabilities'] as Map?)?['tokenize_audio'] == true;

  @override
  Future<void> warmUp() async {
    if (!runtime.installed) return;
    try {
      await process.ensureConfigured();
      _info = await process.request('info');
      notifyListeners();
    } catch (_) {}
  }

  @override
  Future<Map<String, dynamic>> info() async {
    await process.ensureConfigured();
    _info = await process.request('info');
    return _info!;
  }

  Future<Map<String, dynamic>> request(String cmd, [Map<String, dynamic> args = const {}]) async {
    await process.ensureStarted();
    return process.request(cmd, args);
  }

  @override
  Future<void> run(Song song, JobContext ctx) async {
    _current = ctx;
    await process.ensureConfigured();
    final args = <String, dynamic>{
      ...song.params,
      'job': song.id,
      'output_dir': song.dir,
      'title': song.title,
    };
    String cmd;
    switch (song.kind) {
      case 'extend':
        cmd = 'extend';
        args.addAll(song.extend);
        args['source_dir'] = ctx.sourceDir;
      case 'rerender':
        cmd = 'rerender';
        args['source_dir'] = ctx.sourceDir;
      default:
        cmd = 'generate';
        if (song.meta['resume'] == true) args['resume'] = true;
    }
    _running = song.id;
    notifyListeners();
    try {
      await process.request(cmd, args);
    } catch (e) {
      _running = null;
      rethrow;
    }
  }

  @override
  Future<void> cancel(Song song) async {
    try {
      await process.request('cancel', {'job': song.id});
    } catch (_) {}
  }

  void _onEvent(Map<String, dynamic> e) {
    final id = e['job'] as String? ?? '';
    switch (e['event']) {
      case 'sidecar_exit':
        final r = _running;
        _running = null;
        if (r != null) _events.add(EngineJobEnded(r, SongStatus.failed, error: 'Engine process exited (code ${e['code']})'));
        _events.add(EngineExited('code ${e['code']}'));
      case 'progress':
        _events.add(EngineProgress(
          id,
          stage: e['stage'] as String? ?? '',
          label: e['label'] as String? ?? '',
          done: (e['done'] as num?)?.toInt(),
          total: (e['total'] as num?)?.toInt(),
          unit: e['unit'] as String?,
          elapsed: (e['elapsed'] as num?)?.toDouble(),
        ));
      case 'job_done':
        _running = null;
        _events.add(EngineJobEnded(id, SongStatus.done, result: Map<String, dynamic>.from(e['result'] as Map)));
      case 'job_failed':
        _running = null;
        _events.add(EngineJobEnded(id, e['cancelled'] == true ? SongStatus.cancelled : SongStatus.failed,
            error: e['error']?.toString()));
    }
    notifyListeners();
  }

  @override
  Future<void> shutdown() => process.stop();

  @override
  void dispose() {
    _sub.cancel();
    process.dispose();
    _events.close();
    super.dispose();
  }
}
