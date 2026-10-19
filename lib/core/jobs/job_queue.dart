import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../app_info.dart';
import '../engine/engine.dart';
import '../library/library.dart';
import '../library/song.dart';
import '../studio.dart';

/// Live state of a running job (what song.json does not hold while it runs).
class LiveJob {
  LiveJob(this.songId) : startedAt = DateTime.now(), stageStartedAt = DateTime.now();

  final String songId;
  final DateTime startedAt;
  DateTime stageStartedAt;
  String stage = '';
  String label = 'Starting';
  int? done;
  int? total;
  String? unit;
  double? engineElapsed;
  int? tokenFrames;
  Duration? eta;
  bool etaUpperBound = false;
  bool cancelling = false;
  final Map<String, double> stageSeconds = {};

  // When `done` last moved in this stage, and where it first moved (the pace is measured from
  // there: the app can attach in the middle of a step, so the time before the first move says
  // nothing about the pace).
  DateTime lastMoveAt = DateTime.now();
  int? _lastDone;
  DateTime? _firstMoveAt;
  int? _firstMoveDone;

  void markProgress(int? d) {
    if (d == null || d == _lastDone) return;
    final now = DateTime.now();
    if (_lastDone != null) {
      _firstMoveAt ??= now;
      _firstMoveDone ??= d;
      lastMoveAt = now;
    }
    _lastDone = d;
  }

  /// Seconds per unit of progress seen in this stage, once at least [minUnits] went by.
  double? secondsPerUnit({int minUnits = 1}) {
    final t0 = _firstMoveAt, d0 = _firstMoveDone, d = _lastDone;
    if (t0 == null || d0 == null || d == null || d - d0 < minUnits) return null;
    return lastMoveAt.difference(t0).inMilliseconds / 1000 / (d - d0);
  }

  double? get fraction => (done != null && total != null && total! > 0) ? (done! / total!).clamp(0, 1).toDouble() : null;
  Duration get elapsed => engineElapsed != null
      ? Duration(milliseconds: (engineElapsed! * 1000).round())
      : DateTime.now().difference(startedAt);

  void enterStage(String s) {
    if (s == stage) return;
    final now = DateTime.now();
    if (stage.isNotEmpty) {
      stageSeconds[stage] = (stageSeconds[stage] ?? 0) + now.difference(stageStartedAt).inMilliseconds / 1000;
    }
    if (stage == 'semantic' && done != null) tokenFrames = done;
    stage = s;
    stageStartedAt = now;
    lastMoveAt = now;
    _lastDone = _firstMoveDone = null;
    _firstMoveAt = null;
  }

  Map<String, double> closeStages() {
    enterStage('');
    return {for (final e in stageSeconds.entries) e.key: double.parse(e.value.toStringAsFixed(2))};
  }
}

/// One job at a time per device; the rest wait. The queue is persistent: it is the set of songs
/// whose song.json says "queued", oldest queued_at first. On desktop this class feeds the engine;
/// on Android the engine's service runs the queue itself and this class only mirrors it.
class JobQueue extends ChangeNotifier {
  JobQueue(this.studio, this.library) {
    studio.addListener(_engineChanged);
    _engineChanged();
  }

  final Studio studio;
  final Library library;
  final Map<String, LiveJob> live = {};

  /// Songs that ended in this session, newest last (the queue panel shows them until dismissed).
  final List<String> recent = [];
  Engine? _engine;
  StreamSubscription<EngineEvent>? _sub;
  Timer? _ticker;
  bool _pumping = false;

  Engine? get engine => studio.engine;

  void _engineChanged() {
    if (identical(_engine, studio.engine)) return;
    _sub?.cancel();
    _engine = studio.engine;
    _sub = _engine?.events.listen(_onEvent);
  }

  Song? get running {
    for (final s in library.songs) {
      if (s.status == SongStatus.running) return s;
    }
    return null;
  }

  List<Song> get queued => library.queued;
  List<Song> get recentSongs => [for (final id in recent.reversed) ?library.byId(id)];

  /// Recover after a restart. Desktop: a job that was running when the app quit is interrupted
  /// (resumable); queued songs start. Android: the service reports what it is doing.
  Future<void> start() async {
    final e = engine;
    if (e == null) return;
    await e.warmUp();
    if (!e.ownsQueue) {
      for (final s in library.songs.where((s) => s.status == SongStatus.running).toList()) {
        await library.patch(s, {'status': SongStatus.interrupted.name, 'error': 'The app quit while this was running.'});
      }
      unawaited(_pump());
    }
    _ticker ??= Timer.periodic(const Duration(seconds: 1), (t) {
      final r = running;
      if (r != null && live[r.id] != null) {
        _updateEta(r, live[r.id]!);
        notifyListeners();
      }
      // An engine that runs its own queue (the Android service) says on disk when a job ended;
      // its event can be lost (the UI was detached), so look now and then.
      if (r != null && (engine?.ownsQueue ?? false) && t.tick % 5 == 0) {
        final now = Song.load(r.dir, readOnly: r.readOnly)?.status;
        if (now != null && now != SongStatus.running) {
          unawaited(_ended(EngineJobEnded(r.id, now, error: null)));
        }
      }
    });
  }

  /// Create a song and queue it. [fields]: kind, params, parent, source_dir, extend, cover.
  /// [prepare] runs on the new folder before the engine sees the song (e.g. copying a cover's
  /// recording into it).
  Future<Song> submit(String title, Map<String, dynamic> fields, {Future<void> Function(Song song)? prepare}) async {
    final ctx = studio.context();
    final song = await library.create(title, {
      'kind': 'generate',
      'model': {
        'id': ctx.model.id,
        'licence': ctx.model.licence.spdx,
        'format': ctx.format.id,
        'variant': ctx.variant.id,
        'files': {for (final f in ctx.variant.files) f.role: studio.modelFilePath(f)},
      },
      'engine': {'id': studio.engineDescriptor!.id, 'app_version': appVersion},
      ...fields,
    });
    if (prepare != null) await prepare(song);
    await _hand(song);
    return song;
  }

  Future<void> _hand(Song song) async {
    final e = engine;
    if (e == null) return;
    if (e.ownsQueue) {
      await e.run(song, studio.contextFor(song));
    } else {
      unawaited(_pump());
    }
    notifyListeners();
  }

  /// Queue a stopped job again; it continues from its checkpoints.
  Future<void> resume(Song song) async {
    final s = await library.patch(song, {
      'status': SongStatus.queued.name,
      'error': null,
      'resume': true,
      'queued_at': DateTime.now().toIso8601String(),
    });
    recent.remove(song.id);
    await _hand(s);
  }

  Future<void> cancel(Song song) async {
    final fresh = library.reload(song) ?? song;
    if (fresh.status == SongStatus.queued && !(engine?.ownsQueue ?? false)) {
      await library.patch(fresh, {'status': SongStatus.cancelled.name});
      notifyListeners();
      return;
    }
    live[song.id]?.cancelling = true;
    notifyListeners();
    await engine?.cancel(fresh);
    if (engine?.ownsQueue ?? false) await library.refresh();
  }

  /// Move a queued song one place earlier (swap queued_at with its predecessor).
  Future<void> moveUp(Song song) async {
    final q = queued;
    final i = q.indexWhere((s) => s.id == song.id);
    if (i <= 0) return;
    final prev = q[i - 1];
    final a = song.meta['queued_at'], b = prev.meta['queued_at'];
    await library.patch(song, {'queued_at': b});
    await library.patch(prev, {'queued_at': a});
    notifyListeners();
  }

  void dismiss(Song song) {
    recent.remove(song.id);
    notifyListeners();
  }

  void clearRecent() {
    recent.clear();
    notifyListeners();
  }

  Future<void> _pump() async {
    if (_pumping) return;
    final e = engine;
    if (e == null || e.ownsQueue || running != null) return;
    _pumping = true;
    try {
      final next = queued.firstOrNull;
      if (next == null) return;
      final s = await library.patch(next, {'status': SongStatus.running.name, 'started_at': DateTime.now().toIso8601String()});
      live[s.id] = LiveJob(s.id);
      notifyListeners();
      try {
        await e.run(s, studio.contextFor(s));
      } catch (err) {
        await _ended(EngineJobEnded(s.id, SongStatus.failed, error: err.toString()));
      }
    } finally {
      _pumping = false;
    }
  }

  void _onEvent(EngineEvent ev) {
    switch (ev) {
      case EngineProgress():
        final j = live.putIfAbsent(ev.songId, () => LiveJob(ev.songId));
        if (library.byId(ev.songId)?.status != SongStatus.running) {
          // Android: the service started it; pick up the new status from disk.
          library.refresh();
        }
        j.enterStage(ev.stage);
        j.label = ev.label;
        j.done = ev.done;
        j.total = ev.total;
        j.markProgress(ev.done);
        j.unit = ev.unit;
        j.engineElapsed = ev.elapsed;
        final s = library.byId(ev.songId);
        if (s != null) _updateEta(s, j);
        notifyListeners();
      case EngineJobEnded():
        _ended(ev);
      case EngineExited():
        notifyListeners();
    }
  }

  Future<void> _ended(EngineJobEnded ev) async {
    final j = live.remove(ev.songId);
    final e = engine;
    final song = library.byId(ev.songId);
    if (e != null && !e.writesSongMetadata && song != null) {
      final r = ev.result ?? const {};
      final stages = j?.closeStages() ?? const {};
      await library.patch(song, {
        'status': ev.status.name,
        'error': ev.error,
        'resume': null,
        'finished_at': DateTime.now().toIso8601String(),
        if (ev.status == SongStatus.done) ...{
          'audio': r['audio'],
          'render': r['render'],
          'audio_seconds': r['audio_seconds'],
          'token_frames': r['token_frames'],
          'truncated': r['truncated'],
          'engine_timing': r['engine_timing'],
          'section': r['section'],
          'seam': r['seam'],
        },
        'timing': {
          'total_seconds': double.parse(((j?.elapsed.inMilliseconds ?? 0) / 1000).toStringAsFixed(2)),
          'stages': stages,
        },
      });
      if (ev.status == SongStatus.done) _calibrate(song, r);
    } else {
      await library.refresh();
      final fresh = library.byId(ev.songId);
      if (ev.status == SongStatus.done && fresh != null && fresh.meta['engine_timing'] == null) _calibrateFromStages(fresh);
    }
    recent.remove(ev.songId);
    recent.add(ev.songId);
    notifyListeners();
    Future.microtask(_pump);
  }

  // ------------------------------------------------------------------ ETA

  String get _key => engine?.descriptor.id ?? 'engine';

  int _expectedFrames(Song s, LiveJob j) {
    if (j.tokenFrames != null) return j.tokenFrames!;
    final fr = studio.model?.limits.frameRate ?? 25;
    final maxTokens = studio.model?.limits.maxTokens ?? 9000;
    if (s.kind == 'rerender') return ((library.byId(s.parentId)?.seconds ?? 60) * fr).round();
    final ext = s.extend;
    final cap = s.kind == 'extend'
        ? ((ext['section_seconds'] as num? ?? 30) + (ext['add_seconds'] as num? ?? 300)) * fr
        : (s.params['max_seconds'] as num? ?? 360) * fr;
    return math.min(maxTokens, cap.round());
  }

  /// Rates for this device: composing (frames per second), mixing (seconds per frame and step),
  /// mastering (seconds per frame). Calibrated from finished songs; until then the fallbacks.
  /// The phone CPU fallbacks were measured on a Pixel 10 Pro Fold (Q5_K_M, 6 threads, a 2-minute
  /// song): about 0.85 frames/s composing and 0.21 s per frame and step mixing.
  ({double tps, double nar, double vae}) _rates(String? precision) {
    final fast = engine?.descriptor.runtime == 'mlx';
    return (
      tps: studio.settings.calib('ar_tps-$_key-${precision ?? 'q'}', fast ? 40 : 0.85),
      nar: studio.settings.calib('nar_spfs-$_key', fast ? 0.0015 : 0.2),
      vae: studio.settings.calib('vae_spf-$_key', fast ? 0.0015 : 0.02),
    );
  }

  /// How long a song of [seconds] at [steps] would take on this device, before it is queued.
  /// [compose] false: a re-render (the composed tokens are reused).
  Duration estimate({required double seconds, required int steps, String? precision, bool compose = true}) {
    final r = _rates(precision);
    final frames = seconds * (studio.model?.limits.frameRate ?? 25);
    final t = (compose ? frames / r.tps : 0) + frames * steps * r.nar + frames * r.vae;
    return Duration(seconds: t.round());
  }

  void _updateEta(Song s, LiveJob j) {
    final steps = s.solveSteps;
    final rates = _rates(s.precision);
    final tps = rates.tps, narRate = rates.nar, vaeRate = rates.vae;
    final done = j.done ?? 0;
    final sinceMove = DateTime.now().difference(j.lastMoveAt).inMilliseconds / 1000;
    // Time for the units still to come, at the pace measured in this stage (or [fallback] seconds
    // per unit until there is one), counting down while the current unit runs.
    double left(int units, double fallback, {int minUnits = 1}) {
      if (units <= 0) return 0;
      final per = j.secondsPerUnit(minUnits: minUnits) ?? fallback;
      return math.max(units * per - sinceMove, (units - 1) * per);
    }
    var frames = _expectedFrames(s, j);
    var remaining = 0.0;
    var upper = false;
    switch (j.stage) {
      case 'semantic':
        final total = j.total ?? frames;
        remaining += left(total - done, 1 / tps, minUnits: 10);
        frames = total;
        upper = true;
        remaining += frames * steps * narRate + frames * vaeRate;
      case 'nar':
        remaining += left((j.total ?? steps) - done, frames * narRate) + frames * vaeRate;
      case 'vae':
        final tiles = j.total ?? 1;
        remaining += left(tiles - done, frames * vaeRate / math.max(1, tiles));
      case 'post':
        remaining = 1;
      default:
        if (s.kind != 'rerender' && !s.composed) {
          remaining += frames / tps;
          upper = true;
        }
        remaining += frames * steps * narRate + frames * vaeRate;
    }
    j.eta = Duration(seconds: remaining.round());
    j.etaUpperBound = upper;
  }

  /// Engines without their own timing report (the Android service) still record how long each
  /// stage took in song.json; calibrate from that.
  void _calibrateFromStages(Song s) {
    final st = (s.meta['timing'] as Map?)?['stages'];
    final frames = (s.meta['token_frames'] as num?)?.toDouble() ?? 0;
    if (st is! Map || frames <= 0 || s.meta['resume'] == true) return;
    final sem = st['semantic'], nar = st['nar'], vae = st['vae'];
    if (s.kind == 'generate' && sem is num && sem > 1) studio.settings.setCalib('ar_tps-$_key-${s.precision ?? 'q'}', frames / sem);
    if (s.kind == 'extend') return;
    if (nar is num && nar > 0) studio.settings.setCalib('nar_spfs-$_key', nar / (frames * s.solveSteps));
    if (vae is num && vae > 0) studio.settings.setCalib('vae_spf-$_key', vae / frames);
  }

  void _calibrate(Song s, Map<String, dynamic> r) {
    final t = r['engine_timing'];
    if (t is! Map) return;
    final sem = t['semantic'];
    final frames = (r['token_frames'] as num?)?.toInt() ?? 0;
    if (sem is Map && sem['output_tps'] is num && (sem['output_tokens'] as num? ?? 0) > 50) {
      studio.settings.setCalib('ar_tps-$_key-${s.precision ?? 'q'}', (sem['output_tps'] as num).toDouble());
    }
    if (s.kind == 'extend' || frames <= 0) return;
    final steps = s.solveSteps;
    if (t['nar_seconds'] is num) studio.settings.setCalib('nar_spfs-$_key', (t['nar_seconds'] as num) / (frames * steps));
    if (t['vae_seconds'] is num) studio.settings.setCalib('vae_spf-$_key', (t['vae_seconds'] as num) / frames);
  }

  @override
  void dispose() {
    studio.removeListener(_engineChanged);
    _sub?.cancel();
    _ticker?.cancel();
    super.dispose();
  }
}
