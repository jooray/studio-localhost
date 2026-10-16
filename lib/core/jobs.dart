import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'library.dart';
import 'settings.dart';
import 'sidecar.dart';

enum JobStatus { queued, running, done, failed, cancelled }

class Job {
  Job({required this.id, required this.kind, required this.title, required this.args});

  final String id;
  final String kind; // generate | extend | rerender
  final String title;
  final Map<String, dynamic> args;
  String? outputDir;
  JobStatus status = JobStatus.queued;
  String stage = '';
  String label = 'Queued';
  int? done;
  int? total;
  String? unit;
  DateTime? startedAt;
  DateTime? finishedAt;
  DateTime? stageStartedAt;
  int? semanticFrames; // known once the semantic stage ends
  Duration? eta;
  bool etaUpperBound = false;
  String? error;
  Map<String, dynamic>? result;

  double? get fraction => (done != null && total != null && total! > 0) ? (done! / total!).clamp(0, 1).toDouble() : null;
  Duration get elapsed => (startedAt == null) ? Duration.zero : (finishedAt ?? DateTime.now()).difference(startedAt!);
  bool get active => status == JobStatus.queued || status == JobStatus.running;
}

/// One GPU job at a time; everything else waits in a FIFO the user can reorder or prune.
class JobQueue extends ChangeNotifier {
  JobQueue(this.sidecar, this.settings, this.library) {
    _sub = sidecar.events.listen(_onEvent);
  }

  final Sidecar sidecar;
  final Settings settings;
  final Library library;
  final List<Job> jobs = [];
  late final StreamSubscription _sub;
  int _counter = 0;
  Timer? _ticker;

  Job? get running {
    for (final j in jobs) {
      if (j.status == JobStatus.running) return j;
    }
    return null;
  }

  List<Job> get queued => jobs.where((j) => j.status == JobStatus.queued).toList();

  Job add(String kind, String title, Map<String, dynamic> args) {
    final job = Job(id: 'j${DateTime.now().millisecondsSinceEpoch}-${++_counter}', kind: kind, title: title, args: args);
    jobs.add(job);
    notifyListeners();
    _pump();
    return job;
  }

  void remove(Job j) {
    if (j.status == JobStatus.running) return;
    jobs.remove(j);
    notifyListeners();
  }

  void clearFinished() {
    jobs.removeWhere((j) => !j.active);
    notifyListeners();
  }

  void moveUp(Job j) {
    final i = jobs.indexOf(j);
    if (i > 0 && jobs[i - 1].status == JobStatus.queued) {
      jobs.removeAt(i);
      jobs.insert(i - 1, j);
      notifyListeners();
    }
  }

  Future<void> cancel(Job j) async {
    if (j.status == JobStatus.queued) {
      j.status = JobStatus.cancelled;
      j.label = 'Cancelled';
      notifyListeners();
      return;
    }
    if (j.status == JobStatus.running) {
      j.label = 'Cancelling…';
      notifyListeners();
      try {
        await sidecar.request('cancel', {'job': j.id});
      } catch (_) {}
    }
  }

  Future<void> _pump() async {
    if (running != null) return;
    final next = jobs.where((j) => j.status == JobStatus.queued).firstOrNull;
    if (next == null) return;
    next.status = JobStatus.running;
    next.startedAt = DateTime.now();
    next.stageStartedAt = next.startedAt;
    next.label = 'Starting engine';
    notifyListeners();
    _ticker ??= Timer.periodic(const Duration(seconds: 1), (_) {
      if (running != null) {
        _updateEta(running!);
        notifyListeners();
      }
    });
    try {
      await sidecar.ensureStarted();
      if (sidecar.configuredBackend != settings.backend) await sidecar.configure();
      next.outputDir ??= library.newSongDir(next.title);
      await sidecar.request(next.kind, {...next.args, 'job': next.id, 'output_dir': next.outputDir, 'title': next.title});
      next.label = 'Running';
    } catch (e) {
      _finish(next, JobStatus.failed, error: e.toString());
    }
    notifyListeners();
  }

  void _onEvent(Map<String, dynamic> e) {
    if (e['event'] == 'sidecar_exit') {
      final r = running;
      if (r != null) _finish(r, JobStatus.failed, error: 'Engine process exited (code ${e['code']})');
      return;
    }
    final job = jobs.where((j) => j.id == e['job']).firstOrNull;
    if (job == null) return;
    switch (e['event']) {
      case 'progress':
        final stage = e['stage'] as String? ?? '';
        if (stage != job.stage) {
          if (job.stage == 'semantic' && job.done != null) job.semanticFrames = job.done;
          job.stageStartedAt = DateTime.now();
        }
        job.stage = stage;
        job.label = e['label'] as String? ?? stage;
        job.done = (e['done'] as num?)?.toInt();
        job.total = (e['total'] as num?)?.toInt();
        job.unit = e['unit'] as String?;
        _updateEta(job);
        notifyListeners();
      case 'job_done':
        job.result = Map<String, dynamic>.from(e['result'] as Map);
        _calibrate(job);
        _finish(job, JobStatus.done);
      case 'job_failed':
        _finish(job, e['cancelled'] == true ? JobStatus.cancelled : JobStatus.failed, error: e['error']?.toString());
    }
  }

  void _finish(Job job, JobStatus status, {String? error}) {
    job.status = status;
    job.finishedAt = DateTime.now();
    job.error = error;
    job.eta = null;
    job.label = switch (status) {
      JobStatus.done => 'Done',
      JobStatus.cancelled => 'Cancelled',
      _ => 'Failed',
    };
    notifyListeners();
    library.refresh();
    Future.microtask(_pump);
  }

  // ------------------------------------------------------------------ ETA

  String get _calibKey => '${settings.backend}-${running?.args['precision'] ?? 'q'}';

  int _expectedFrames(Job j) {
    if (j.semanticFrames != null) return j.semanticFrames!;
    if (j.kind == 'rerender') return ((j.args['source_seconds'] as num? ?? 60) * 25).round();
    final cap = j.kind == 'extend'
        ? ((j.args['section_seconds'] as num? ?? 30) + (j.args['add_seconds'] as num? ?? 300)) * 25
        : (j.args['max_seconds'] as num? ?? 360) * 25;
    return math.min(9000, cap.round());
  }

  void _updateEta(Job j) {
    final steps = (j.args['steps'] as num?)?.toInt() ?? 32;
    final tps = settings.calib('ar_tps-$_calibKey', settings.backend == 'mlx' ? 40 : 15);
    final narRate = settings.calib('nar_spfs-${settings.backend}', settings.backend == 'mlx' ? 0.0015 : 0.01);
    final vaeRate = settings.calib('vae_spf-${settings.backend}', 0.0015);
    final stageElapsed = j.stageStartedAt == null ? 0.0 : DateTime.now().difference(j.stageStartedAt!).inMilliseconds / 1000;
    final done = j.done ?? 0;
    double liveRate(double fallback) => (done > 10 && stageElapsed > 1) ? done / stageElapsed : fallback;
    var frames = _expectedFrames(j);
    var remaining = 0.0;
    var upper = false;
    switch (j.stage) {
      case 'semantic':
        final rate = liveRate(tps);
        final total = j.total ?? frames;
        remaining += math.max(0, total - done) / rate;
        frames = (j.kind == 'extend') ? total + ((j.args['section_seconds'] as num? ?? 0) * 25).round() : total;
        upper = true;
        remaining += frames * steps * narRate + frames * vaeRate;
      case 'nar':
        final rate = liveRate(1 / math.max(1e-6, frames * narRate));
        remaining += math.max(0, (j.total ?? steps) - done) / rate + frames * vaeRate;
      case 'vae':
        final rate = liveRate(1);
        remaining += math.max(0, (j.total ?? 1) - done) / rate;
      case 'post':
        remaining = 1;
      default:
        // loading / planning: assume the rest runs at calibrated rates
        if (j.kind != 'rerender') {
          remaining += frames / tps;
          upper = true;
        }
        if (j.stage == 'plan') remaining += math.max(0, 1200 - done) / liveRate(tps);
        remaining += frames * steps * narRate + frames * vaeRate;
    }
    j.eta = Duration(seconds: remaining.round());
    j.etaUpperBound = upper;
  }

  void _calibrate(Job j) {
    final t = j.result?['timing'];
    if (t is! Map) return;
    final sem = t['semantic'];
    final frames = (j.result?['semantic_frames'] as num?)?.toInt() ?? ((j.result?['audio_seconds'] as num? ?? 0) * 25).round();
    if (sem is Map && sem['output_tps'] is num && (sem['output_tokens'] as num? ?? 0) > 50) {
      settings.setCalib('ar_tps-$_calibKey', (sem['output_tps'] as num).toDouble());
    }
    if (j.kind == 'extend') return; // the timeline frames differ from the rendered frames
    final steps = (j.args['steps'] as num?)?.toInt() ?? 32;
    if (t['nar_seconds'] is num && frames > 0) {
      settings.setCalib('nar_spfs-${settings.backend}', (t['nar_seconds'] as num) / (frames * steps));
    }
    if (t['vae_seconds'] is num && frames > 0) {
      settings.setCalib('vae_spf-${settings.backend}', (t['vae_seconds'] as num) / frames);
    }
  }

  @override
  void dispose() {
    _sub.cancel();
    _ticker?.cancel();
    super.dispose();
  }
}
