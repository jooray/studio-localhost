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
    _ticker ??= Timer.periodic(const Duration(seconds: 1), (_) {
      final r = running;
      if (r != null && live[r.id] != null) {
        _updateEta(r, live[r.id]!);
        notifyListeners();
      }
    });
  }

  /// Create a song and queue it. [fields]: kind, params, parent, source_dir, extend.
  Future<Song> submit(String title, Map<String, dynamic> fields) async {
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

  void _updateEta(Song s, LiveJob j) {
    final steps = s.steps ?? 32;
    final prec = s.precision ?? 'q';
    final fast = engine?.descriptor.runtime == 'mlx';
    final tps = studio.settings.calib('ar_tps-$_key-$prec', fast ? 40 : 8);
    final narRate = studio.settings.calib('nar_spfs-$_key', fast ? 0.0015 : 0.03);
    final vaeRate = studio.settings.calib('vae_spf-$_key', fast ? 0.0015 : 0.02);
    final stageElapsed = DateTime.now().difference(j.stageStartedAt).inMilliseconds / 1000;
    final done = j.done ?? 0;
    double liveRate(double fallback) => (done > 10 && stageElapsed > 1) ? done / stageElapsed : fallback;
    var frames = _expectedFrames(s, j);
    var remaining = 0.0;
    var upper = false;
    switch (j.stage) {
      case 'semantic':
        final rate = liveRate(tps);
        final total = j.total ?? frames;
        remaining += math.max(0, total - done) / rate;
        frames = total;
        upper = true;
        remaining += frames * steps * narRate + frames * vaeRate;
      case 'nar':
        final rate = liveRate(1 / math.max(1e-6, frames * narRate));
        remaining += math.max(0, (j.total ?? steps) - done) / rate + frames * vaeRate;
      case 'vae':
        remaining += math.max(0, (j.total ?? 1) - done) / liveRate(1);
      case 'post':
        remaining = 1;
      default:
        if (s.kind != 'rerender') {
          remaining += frames / tps;
          upper = true;
        }
        remaining += frames * steps * narRate + frames * vaeRate;
    }
    j.eta = Duration(seconds: remaining.round());
    j.etaUpperBound = upper;
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
    final steps = s.steps ?? 32;
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
