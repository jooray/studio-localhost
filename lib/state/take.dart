import 'package:flutter/foundation.dart';

import '../core/audio/envelope.dart';
import '../core/jobs/job_queue.dart';
import '../core/library/catalogue.dart';
import '../core/library/envelopes.dart';
import '../core/library/library.dart';
import '../core/library/song.dart';
import '../core/paths.dart';
import '../core/player.dart';
import '../core/studio.dart';

enum TakeMode { empty, idle, playing, recording, waiting, failed }

/// One cell of the catalogue index bar.
class IndexEntry {
  const IndexEntry(this.number, this.song, {this.current = false});
  final int number;
  final Song? song;
  final bool current;
  bool get running => song?.status == SongStatus.running;
  bool get queued => song?.status == SongStatus.queued;
  bool get failed => song?.status == SongStatus.failed || song?.status == SongStatus.interrupted;
}

/// What the main screen shows about "the take": the song being recorded, played or last made,
/// its status line, the progress arc and the catalogue index around it. Pure state, no widgets.
class TakeState extends ChangeNotifier {
  TakeState(this.studio, this.library, this.queue, this.player, this.envelopes) {
    for (final l in <Listenable>[studio, library, queue, envelopes]) {
      l.addListener(notifyListeners);
    }
    player.addListener(_onPlayer);
  }

  bool _drafting = false;
  bool _wasPlaying = false;

  /// The sheet under the plot holds the draft for the next song (editable). Otherwise it shows
  /// the current song's own words, read-only. With no song at all there is only the draft.
  bool get drafting => _drafting || current == null;

  /// The song whose words the sheet shows, or null while drafting.
  Song? get sheetSong => drafting ? null : current;

  /// Open the draft for the next song.
  void draft() {
    if (_drafting) return;
    _drafting = true;
    notifyListeners();
  }

  /// Let the sheet follow the current song again (after Record, or when playback starts).
  void listen() {
    if (!_drafting) return;
    _drafting = false;
    notifyListeners();
  }

  void _onPlayer() {
    final p = player.playing;
    // Starting playback is choosing a song to listen to: the sheet follows it.
    if (p && !_wasPlaying) _drafting = false;
    _wasPlaying = p;
    notifyListeners();
  }

  final Studio studio;
  final Library library;
  final JobQueue queue;
  final AudioPlayerModel player;
  final Envelopes envelopes;

  Song? get running => queue.running;

  Song? get playingSong {
    final path = player.path;
    if (path == null) return null;
    for (final s in library.songs) {
      if (s.audioPath == path || s.renderPath == path) return s;
    }
    return null;
  }

  Song? get lastDone {
    for (final s in library.byCatalogue) {
      if (s.status == SongStatus.done && s.hasAudio) return s;
    }
    return null;
  }

  /// The newest job that ended badly in this session and was not dismissed.
  Song? get failed {
    final r = queue.recentSongs;
    if (r.isEmpty) return null;
    final s = r.first;
    return (s.status == SongStatus.failed || s.status == SongStatus.interrupted) ? s : null;
  }

  Song? get current => running ?? playingSong ?? failed ?? lastDone;

  TakeMode get mode {
    if (running != null) return TakeMode.recording;
    if (playingSong != null && (player.playing || player.position > Duration.zero)) return TakeMode.playing;
    if (failed != null) return TakeMode.failed;
    if (queue.queued.isNotEmpty) return TakeMode.waiting;
    return lastDone == null ? TakeMode.empty : TakeMode.idle;
  }

  int? number(Song? s) => s == null ? null : library.number(s);

  int get nextNumber => library.catalogue.next;

  LiveJob? get live {
    final r = running;
    return r == null ? null : queue.live[r.id];
  }

  /// Words of the engraved status line for a running entry, whether or not it is the studio's
  /// current take: the phase it is in, its number, and the time left (or frames composed).
  List<String> recordingStatus(Song s) {
    final j = queue.live[s.id];
    final word = _stageWord(j?.stage ?? '');
    final n = Catalogue.format(number(s));
    if (j == null) return [word, n];
    if (j.stage == 'semantic' && j.done != null) {
      final fr = studio.model?.limits.frameRate ?? 25;
      final total = (j.total ?? 0) > 0 ? j.total! / fr : s.targetSeconds;
      return [word, n, '${formatDuration(j.done! / fr)} / ${formatDuration(total)}'];
    }
    if (j.eta != null && j.stage.isNotEmpty) {
      return [word, n, '${j.etaUpperBound ? '≤' : '≈'}${formatDuration(j.eta!.inSeconds)} left'.toUpperCase()];
    }
    return [word, n];
  }

  /// How far a running entry is, 0..1. Without a fraction for the stage, the ETA gives it.
  double? progressFor(Song s) => _progress(queue.live[s.id]);

  /// Words of the engraved status line, joined with " · " by the UI.
  List<String> get status {
    final s = current;
    switch (mode) {
      case TakeMode.recording:
        return recordingStatus(s!);
      case TakeMode.playing:
        return [
          Catalogue.format(number(s)),
          '${formatDuration(player.position.inMilliseconds / 1000)} / ${formatDuration(_duration(s))}',
        ];
      case TakeMode.failed:
        return [s!.status == SongStatus.failed ? 'FAILED' : 'STOPPED', Catalogue.format(number(s))];
      case TakeMode.waiting:
        return ['QUEUED', Catalogue.format(number(queue.queued.first))];
      case TakeMode.idle:
        return [Catalogue.format(number(s)), formatDuration(s!.seconds)];
      case TakeMode.empty:
        return ['NO RECORDINGS YET'];
    }
  }

  /// What the sheet's words are to the shown song: its record, or the prompt of a song still
  /// being made (with the time left while it records).
  String sheetNote(Song s) {
    switch (s.status) {
      case SongStatus.running:
        final j = queue.live[s.id];
        final word = s.previewPath != null ? 'preview ready' : 'recording';
        if (j?.eta == null) return word;
        return '$word · ${j!.etaUpperBound ? '≤' : '≈'}${formatDuration(j.eta!.inSeconds)} left';
      case SongStatus.queued:
        return 'queued';
      case SongStatus.done:
        return 'as recorded';
      default:
        return 'stopped';
    }
  }

  /// The title that leads the status line when a finished song is shown (idle, playing).
  String? get lead {
    final s = current;
    if (s == null) return null;
    if (mode != TakeMode.idle && mode != TakeMode.playing) return null;
    final t = library.titleOf(s);
    return t == Catalogue.format(number(s)) ? null : t;
  }

  double _duration(Song? s) {
    final d = player.duration.inMilliseconds / 1000;
    return d > 0 ? d : (s?.seconds ?? 0);
  }

  static String _stageWord(String stage) => switch (stage) {
        'load' => 'WARMING UP',
        'listen' => 'LISTENING',
        'plan' => 'SCORING',
        'semantic' => 'RECORDING',
        'nar' => 'MIXING',
        'vae' => 'MASTERING',
        'post' => 'FILING',
        _ => 'STARTING',
      };

  /// The outer-ring arc, 0..1, or null for none.
  double? get arc {
    switch (mode) {
      case TakeMode.recording:
        return _progress(live);
      case TakeMode.playing:
        final d = _duration(playingSong);
        return d > 0 ? (player.position.inMilliseconds / 1000 / d).clamp(0.0, 1.0) : 0;
      default:
        return null;
    }
  }

  /// Token progress of the running take (drives the placeholder burst), 0..1.
  double get tokenProgress {
    final j = live;
    if (j == null) return 0;
    if (j.stage == 'semantic') return j.fraction ?? 0;
    return const {'load': 0.0, 'listen': 0.0, 'plan': 0.02}[j.stage] ?? 1.0;
  }

  /// The plot data: the current song's envelope, or for a running extend/re-render its source.
  Envelope? get envelope {
    final s = current;
    final own = envelopes.of(s);
    if (own != null || s == null) return own;
    if (s.active && s.parentId != null) return envelopes.of(library.byId(s.parentId));
    return null;
  }

  /// The last four catalogue numbers (made, running, queued), oldest left.
  List<IndexEntry> get index {
    final cur = number(current);
    final all = library.byCatalogue.where((s) => library.number(s) != null).take(4).toList().reversed;
    return [for (final s in all) IndexEntry(library.number(s)!, s, current: library.number(s) == cur)];
  }

  /// Short error for the engine, if it cannot run at all.
  String? get engineFault => studio.engine?.fault;

  @override
  void dispose() {
    for (final l in <Listenable>[studio, library, queue, envelopes]) {
      l.removeListener(notifyListeners);
    }
    player.removeListener(_onPlayer);
    super.dispose();
  }
}

/// How far a live job is, 0..1: its stage fraction, or elapsed against the ETA where the stage
/// reports units too coarsely to move (loading, listening windows).
double _progress(LiveJob? j) {
  if (j == null) return 0;
  if (j.eta != null) {
    final el = j.elapsed.inMilliseconds / 1000, left = j.eta!.inMilliseconds / 1000;
    if (el + left > 0) return (el / (el + left)).clamp(0.0, 1.0);
  }
  return (j.fraction ?? 0).clamp(0.0, 1.0);
}
