import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'audio/envelope.dart';
import 'jobs/job_queue.dart';
import 'library/catalogue.dart';
import 'library/envelopes.dart';
import 'library/library.dart';
import 'library/song.dart';
import 'paths.dart';
import 'player.dart';
import 'settings.dart';

/// Demo content for captures (`STUDIO_DEMO=<folder with song folders>`): the approved comp's
/// words verbatim, catalogue entries LRS-012..014 made from real song folders and LRS-015
/// "recording" at 2:14 of 4:00 with a real envelope. Only ever used with a scratch
/// STUDIO_DATA_DIR; it writes song folders there, never into the source folders.
class Demo {
  static const style = 'cinematic dark jazz, mournful trombone, brushed drums, Rhodes';
  static const lyrics = '[Verse]\nNeon fades along the lane\nFootsteps keep the time of rain\n\n[Chorus]\nLet the night come into view\n';

  /// Source folders by catalogue number (each with an audio.flac).
  static const sources = {12: 'instrumental_3', 13: 'vocalise_2', 14: 'instrumental_2', 15: 'vocalise_1'};

  /// A seed whose code strip is the comp's: grey, blue, gold, red, white (double width).
  static int compSeed() {
    for (var s = 1; s < 1 << 24; s++) {
      final b = codeStrip(s);
      if (b.map((x) => x.colour).join() == '01234' && b.map((x) => x.weight).join() == '11112') return s;
    }
    return 0;
  }

  /// Write the song folders and form state. Call before the library's first refresh.
  static Future<void> seed(String sourceRoot, Settings settings) async {
    final lib = AppPaths.instance.libraryDir;
    await Directory(lib).create(recursive: true);
    settings.importRoots = [];
    settings.lastForm = {
      'style': style,
      'lyrics': lyrics,
      'mode': 'full',
      'steps': 32,
      'precision': '8bit',
      'limitLength': true,
      'maxSeconds': 240.0,
      'seed': compSeed(),
    };
    var day = DateTime(2026, 10, 12, 21);
    for (final e in sources.entries) {
      final n = e.key;
      final src = p.join(sourceRoot, e.value);
      final dir = p.join(lib, 'demo-lrs-$n');
      await Directory(dir).create(recursive: true);
      final running = n == 15;
      final req = _json(p.join(src, 'request.json'));
      final res = _json(p.join(src, 'result.json'));
      final audio = File(p.join(src, 'audio.flac'));
      if (!running && audio.existsSync()) {
        final link = Link(p.join(dir, 'audio.flac'));
        if (!link.existsSync()) await link.create(audio.path);
      }
      final meta = {
        'format': Song.format,
        'version': Song.formatVersion,
        'id': 'demo-lrs-$n',
        // One entry carries a user title; the others show titles derived from their words.
        'title': n == 14 ? 'Run Towards The Sun' : e.value.replaceAll('_', ' '),
        'title_user': n == 14,
        'created': day.add(Duration(hours: n)).toIso8601String(),
        'kind': 'generate',
        'status': running ? 'running' : 'done',
        'catalogue': n,
        'model': {'id': 'yue2-3b', 'licence': 'CC-BY-NC-4.0', 'format': 'mlx', 'variant': '8bit'},
        'engine': {'id': 'sidecar-mlx'},
        'params': {
          'style': running ? style : (req['style'] ?? ''),
          'lyrics': running ? lyrics : (req['lyrics'] ?? ''),
          'seed': running ? compSeed() : (req['seed'] ?? n * 7919),
          'steps': 32,
          'precision': '8bit',
          'max_seconds': 240,
        },
        if (!running) 'audio': 'audio.flac',
        if (!running) 'audio_seconds': n == 14 ? 240.0 : res['audio_seconds'],
      };
      await File(p.join(dir, 'song.json')).writeAsString(const JsonEncoder.withIndent('  ').convert(meta));
      day = day.add(const Duration(days: 1));
    }
  }

  /// After the library loaded: the running take's live progress and its plot.
  static Future<void> live(String sourceRoot, Library library, JobQueue queue, Envelopes envelopes) async {
    final s = library.byId('demo-lrs-15');
    if (s == null) return;
    final j = LiveJob(s.id)
      ..stage = 'semantic'
      ..label = 'Tokens'
      ..done = 134 * 25
      ..total = 240 * 25
      ..unit = 'frames';
    queue.live[s.id] = j;
    final e = await computeEnvelope(p.join(sourceRoot, sources[15]!, 'audio.flac'), bins: Envelopes.bins);
    if (e != null) envelopes.pin(s.dir, e);
  }


  /// Lyrics of 40 lines (captures of the growing sheet).
  static String forty() {
    final b = StringBuffer();
    const tags = ['[Verse]', '[Pre-Chorus]', '[Chorus]', '[Bridge]'];
    for (var i = 0; i < 40; i++) {
      if (i % 8 == 0) b.writeln(tags[(i ~/ 8) % tags.length]);
      b.writeln('Line ${i + 1}: neon fades along the lane, footsteps keep the time');
    }
    return b.toString();
  }

  /// Put LRS-015 into a state: running (as seeded), idle (finished), playing, or failed.
  static Future<void> state(String name, String sourceRoot, Library library, JobQueue queue, AudioPlayerModel player) async {
    final s = library.byId('demo-lrs-15');
    if (s == null) return;
    final audio = p.join(s.dir, 'audio.flac');
    if (name == 'idle' || name == 'playing') {
      queue.live.remove(s.id);
      final link = Link(audio);
      if (!link.existsSync()) await link.create(p.join(sourceRoot, sources[15]!, 'audio.flac'));
      await library.patch(s, {'status': 'done', 'audio': 'audio.flac', 'audio_seconds': 299.92, 'error': null});
      if (name == 'playing') {
        await player.setVolume(0);
        await player.play(audio, title: 'LRS-015');
        await Future.delayed(const Duration(milliseconds: 600));
        await player.seek(const Duration(seconds: 62));
      } else {
        await player.stopIf(s.dir);
      }
    } else if (name == 'error') {
      await player.stopIf(s.dir);
      queue.live.remove(s.id);
      await library.patch(s, {'status': 'failed', 'error': 'Engine process exited (code -9): out of memory while loading the model'});
      queue.recent
        ..remove(s.id)
        ..add(s.id);
    }
  }

  static Map<String, dynamic> _json(String path) {
    try {
      return Map<String, dynamic>.from(jsonDecode(File(path).readAsStringSync()) as Map);
    } catch (_) {
      return {};
    }
  }
}
