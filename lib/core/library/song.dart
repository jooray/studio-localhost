import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'catalogue.dart';

/// Job/song states, shared with the engines (song.json "status").
enum SongStatus { queued, running, done, failed, cancelled, interrupted }

SongStatus parseStatus(String? s) =>
    SongStatus.values.firstWhere((v) => v.name == s, orElse: () => SongStatus.done);

/// One song folder. The metadata lives in song.json (format "studio-localhost/song", version 1),
/// written by the app and updated by the Android engine while a job runs:
///
/// ```
/// { "format": "studio-localhost/song", "version": 1,
///   "id", "title", "created", "kind": "generate|extend|rerender|cover", "status", "error",
///   "queued_at", "resume",
///   "model": {"id", "licence", "format", "variant"}, "engine": {"id", "app_version"},
///   "params": {"style", "lyrics", "instrumental", "mode", "seed", "steps", "precision",
///              "max_seconds", "abc"},
///   "parent", "source_dir",
///   "extend": {"section_start", "section_end", "add_seconds", "crossfade"},
///   "cover": {"source_audio" (relative to the folder), "source_name", "transcriber"},
///   "audio": "audio.flac|audio.mp3", "render", "audio_seconds", "token_frames",
///   "truncated": {"abc", "semantic"}, "section", "seam",
///   "timing": {"total_seconds", "stages": {"load", "listen", "plan", "semantic", "nar", "vae", "post"}},
///   "engine_timing": {...} }
/// ```
/// Next to it: audio, render (extend), tokens.csv (whole timeline), score.abc, work/ (checkpoints).
class Song {
  Song(this.dir, this.meta, {this.readOnly = false, this.legacy = false});

  static const format = 'studio-localhost/song';
  static const formatVersion = 1;

  final String dir;
  final Map<String, dynamic> meta;
  final bool readOnly;

  /// Imported from an older layout (read-only, best-effort fields).
  final bool legacy;

  String get id => meta['id'] as String? ?? p.basename(dir);
  String get title {
    final t = meta['title'];
    return t is String && t.trim().isNotEmpty ? t.trim() : p.basename(dir);
  }

  DateTime get created => DateTime.tryParse(meta['created'] as String? ?? '')?.toLocal() ?? DateTime.fromMillisecondsSinceEpoch(0);
  DateTime? get queuedAt => DateTime.tryParse(meta['queued_at'] as String? ?? '');
  String get kind => meta['kind'] as String? ?? 'generate';
  SongStatus get status => parseStatus(meta['status'] as String?);
  String? get error => meta['error'] as String?;
  bool get active => status == SongStatus.queued || status == SongStatus.running;
  bool get resumable => !readOnly && (status == SongStatus.failed || status == SongStatus.cancelled || status == SongStatus.interrupted);

  Map<String, dynamic> _map(String k) => Map<String, dynamic>.from(meta[k] as Map? ?? const {});
  Map<String, dynamic> get params => _map('params');
  Map<String, dynamic> get model => _map('model');
  Map<String, dynamic> get engine => _map('engine');
  Map<String, dynamic> get extend => _map('extend');
  Map<String, dynamic> get timing => _map('timing');
  Map<String, dynamic> get engineTiming => _map('engine_timing');
  Map<String, dynamic>? get section => meta['section'] is Map ? _map('section') : null;
  Map<String, dynamic>? get seam => meta['seam'] is Map ? _map('seam') : null;

  String? get modelId => model['id'] as String?;
  String? get licenceId => model['licence'] as String?;
  String? get engineId => engine['id'] as String?;
  String? get parentId => meta['parent'] as String?;
  String? get sourceDir => meta['source_dir'] as String?;

  String get style => params['style'] as String? ?? '';
  String get lyrics => params['lyrics'] as String? ?? '';
  String get mode => params['mode'] as String? ?? '';
  bool get instrumental => params['instrumental'] == true;
  int? get seed => (params['seed'] as num?)?.toInt();
  int? get steps => (params['steps'] as num?)?.toInt();
  String? get precision => params['precision'] as String?;
  double get seconds => (meta['audio_seconds'] as num?)?.toDouble() ?? 0;

  /// The title was given by the user (otherwise it is derived from lyrics or style).
  bool get userTitle => meta['title_user'] == true;

  /// The title derived from the lyrics or style, null when there is nothing to derive from.
  String? get derivedTitle => deriveTitle(lyrics: lyrics, style: style, instrumental: instrumental);

  /// Catalogue number stored in song.json (own songs); the library's catalogue is authoritative.
  int? get ownNumber => (meta['catalogue'] as num?)?.toInt();

  /// The seed behind the song's colour code strip.
  int get codeSeed => seed ?? seedFromText(id);

  /// Target length in seconds while the song is being made (0 when unknown).
  double get targetSeconds {
    final max = params['max_seconds'];
    if (kind == 'extend') {
      final e = extend;
      final start = (e['section_start'] as num?)?.toDouble() ?? 0;
      final sec = (e['section_seconds'] as num?)?.toDouble() ?? 30;
      final add = (e['add_seconds'] as num?)?.toDouble();
      return add == null ? 0 : start + sec + add;
    }
    return max is num ? max.toDouble() : 0;
  }

  String? _file(String? name) => name != null && File(p.join(dir, name)).existsSync() ? p.join(dir, name) : null;

  String? get audioPath =>
      _file(meta['audio'] as String?) ?? _file('audio.flac') ?? _file('audio.mp3') ?? _file('audio.wav');
  String? get renderPath => _file(meta['render'] as String?);
  bool get hasAudio => audioPath != null;

  /// The finished mix is saved (work/latents.f32), so the song can be refined without mixing
  /// from scratch.
  bool get hasLatents => File(p.join(dir, 'work', 'latents.f32')).existsSync();

  /// The song's stream is already composed (a stopped job resumes without composing again).
  bool get composed => File(p.join(dir, 'work', 'tokens.csv')).existsSync();

  /// A refine job: only the tail of the step schedule runs.
  bool get refine => params['refine'] == true;

  /// Flow-matching steps the engine actually runs (a refine runs the tail of its schedule).
  int get solveSteps {
    final s = steps ?? 32;
    if (!refine) return s;
    final t = (params['refine_t'] as num?)?.toDouble() ?? 0.25;
    return (t * s).round().clamp(1, s);
  }

  /// A cover: the recording it was transcribed from ({source_audio, source_name, transcriber}).
  Map<String, dynamic> get cover => _map('cover');

  /// The recording a cover listens to (its copy in the song folder).
  /// A cover whose recording was already transcribed (work/cover.abc).
  bool get transcribed => File(p.join(dir, 'work', 'cover.abc')).existsSync();

  String? get coverSourcePath {
    final s = cover['source_audio'] as String?;
    if (s == null) return null;
    return p.isAbsolute(s) ? s : p.join(dir, s);
  }

  /// A preview of the song while it is still mixing (written by the engine partway through).
  String? get previewPath => _file('work/preview.flac') ?? _file('work/preview.wav');

  /// The song's token stream exists, so it can be re-rendered and extended.
  bool get hasTokens => File(p.join(dir, 'tokens.csv')).existsSync() || File(p.join(dir, 'semantic.npy')).existsSync();

  String? get abc {
    final f = File(p.join(dir, 'score.abc'));
    if (f.existsSync()) {
      try {
        return f.readAsStringSync();
      } catch (_) {}
    }
    return params['abc'] as String?;
  }

  Map<String, bool> get truncated {
    final t = meta['truncated'];
    if (t is Map) return {for (final e in t.entries) e.key.toString(): e.value == true};
    return {};
  }

  /// True when the token stage hit a length cap the user asked for (not an accident).
  bool get stoppedAtRequestedLength {
    final max = params['max_seconds'] ?? extend['add_seconds'];
    return truncated['semantic'] == true && max is num && max > 0;
  }

  bool get truncationWarning => truncated['abc'] == true || (truncated['semantic'] == true && !stoppedAtRequestedLength);

  static Song? load(String dir, {bool readOnly = false}) {
    final f = File(p.join(dir, 'song.json'));
    if (!f.existsSync()) return null;
    try {
      final m = Map<String, dynamic>.from(jsonDecode(f.readAsStringSync()) as Map);
      if (m['format'] != format) return null;
      return Song(dir, m, readOnly: readOnly);
    } catch (_) {
      return null;
    }
  }
}
