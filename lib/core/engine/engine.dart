import 'dart:async';

import 'package:flutter/foundation.dart';

import '../library/song.dart';
import '../models/registry.dart';

/// What an engine is and what it can run. Engines are adapters: each one declares the model
/// families and the model format it runs.
class EngineDescriptor {
  const EngineDescriptor({
    required this.id,
    required this.label,
    required this.runtime,
    required this.families,
    required this.hosts,
    this.precisions = const [],
    this.speedHint = '',
    this.background = '',
  });

  /// e.g. sidecar-mlx, sidecar-yue2cpp, android-native
  final String id;
  final String label;

  /// The runtime adapter that executes jobs.
  final String runtime;

  /// Model families this engine can run.
  final List<String> families;

  /// Hosts it runs on: android, macos-arm64, macos, linux.
  final List<String> hosts;

  /// Run-time precision choices (empty: fixed by the downloaded variant).
  final List<String> precisions;

  /// One line on expected speed, shown in setup only.
  final String speedHint;

  /// One line on how long jobs behave (background, resume), shown in setup only.
  final String background;

  bool runs(ModelSpec m) => families.contains(m.family) && m.formatFor(id) != null;
}

/// Everything an engine needs to run one job.
class JobContext {
  const JobContext({required this.model, required this.format, required this.variant, this.sourceDir});

  final ModelSpec model;
  final ModelFormat format;
  final ModelVariant variant;

  /// The folder of the song a re-render or extension starts from.
  final String? sourceDir;
}

sealed class EngineEvent {
  const EngineEvent(this.songId);
  final String songId;
}

/// Progress of the running job. [stage] is one of load, listen, plan, semantic, nar, vae, post.
class EngineProgress extends EngineEvent {
  const EngineProgress(super.songId,
      {required this.stage, this.label = '', this.done, this.total, this.unit, this.elapsed});

  final String stage;
  final String label;
  final int? done;
  final int? total;
  final String? unit;
  final double? elapsed;
}

/// A job ended. [result] is merged into song.json by engines that do not write it themselves.
class EngineJobEnded extends EngineEvent {
  const EngineJobEnded(super.songId, this.status, {this.error, this.result});

  final SongStatus status;
  final String? error;
  final Map<String, dynamic>? result;
}

/// The engine process went away (desktop sidecar crash).
class EngineExited extends EngineEvent {
  const EngineExited(this.message) : super('');
  final String message;
}

abstract class Engine extends ChangeNotifier {
  EngineDescriptor get descriptor;

  Stream<EngineEvent> get events;

  /// True when the engine keeps its own persistent queue (Android: the foreground service runs
  /// queued songs one after another even while the UI is gone). Otherwise the app's JobQueue
  /// hands over one job at a time.
  bool get ownsQueue;

  /// The engine writes status, result and timing into song.json itself.
  bool get writesSongMetadata;

  /// Short human status ("Ready", "Starting", an error).
  String get statusText;

  /// Set when the engine cannot run jobs (the process failed to start or crashed).
  String? get fault => null;
  bool get busy;

  Future<void> warmUp() async {}

  /// Start (or queue) the job for a song whose folder and song.json already exist.
  Future<void> run(Song song, JobContext ctx);

  Future<void> cancel(Song song);

  /// Detailed diagnostics for the settings screen.
  Future<Map<String, dynamic>> info() async => const {};

  /// Can this engine turn an external recording into tokens (extend external audio)?
  bool get canTokenizeAudio => false;

  /// Can this engine transcribe a recording and cover it (its transcriber is installed)?
  /// Engines that run from files the app downloads answer through [Studio.coverReady] instead.
  bool get canCover => false;

  Future<void> shutdown() async {}
}
