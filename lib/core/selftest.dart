import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'jobs/job_queue.dart';
import 'library/library.dart';
import 'library/song.dart';
import 'studio.dart';

/// Headless end-to-end check through the real app path (JobQueue -> engine -> song folder):
/// `STUDIO_SELFTEST=<report dir>` generates a short song at 8 steps, extends it by 15 s and writes
/// selftest.json. STUDIO_SELFTEST_QUIT=1 exits afterwards.
Future<void> runSelfTest(String reportDir, Studio studio, JobQueue q, Library lib) async {
  final report = <String, dynamic>{
    'started': DateTime.now().toIso8601String(),
    'engine': studio.engineDescriptor?.id,
    'model': studio.model?.id,
    'variant': studio.variant?.id,
    'hardware': studio.hardware.description,
  };
  const style = 'upbeat indie pop, female vocal, acoustic guitar, bright';
  const lyrics = '[Verse]\nPaper boats along the shore\nCounting waves and nothing more\n'
      '[Chorus]\nHold the light, hold it near\nSummer is already here\n';

  Future<Song> wait(Song s, String key) async {
    final sw = Stopwatch()..start();
    while (true) {
      await Future.delayed(const Duration(milliseconds: 500));
      final fresh = lib.byId(s.id) ?? s;
      if (!fresh.active) {
        report['${key}_wall_seconds'] = sw.elapsedMilliseconds / 1000;
        return fresh;
      }
    }
  }

  Map<String, dynamic> summary(Song s) => {
        'status': s.status.name,
        'error': s.error,
        'dir': s.dir,
        'audio_seconds': s.seconds,
        'timing': s.timing,
        'model': s.model,
        'engine': s.engine,
      };

  try {
    await Future.delayed(const Duration(seconds: 2));
    final precision = studio.engineDescriptor?.precisions.isNotEmpty == true ? '8bit' : null;
    final g = await wait(
        await q.submit('Selftest song', {
          'kind': 'generate',
          'params': {
            'style': style,
            'lyrics': lyrics,
            'instrumental': false,
            'mode': 'off',
            'seed': 2026,
            'steps': 8,
            'precision': ?precision,
            'max_seconds': 25,
          },
        }),
        'generate');
    report['generate'] = summary(g);
    if (g.status != SongStatus.done) throw StateError('generate failed: ${g.error}');
    final secs = g.seconds;
    final e = await wait(
        await q.submit('Selftest song (extended)', {
          'kind': 'extend',
          'parent': g.id,
          'source_dir': g.dir,
          'params': {
            'style': style,
            'lyrics': lyrics,
            'mode': 'off',
            'seed': 2027,
            'steps': 8,
            'precision': ?precision,
          },
          'extend': {
            'section_start': (secs - 10).clamp(0, secs),
            'section_end': null,
            'section_seconds': 10,
            'add_seconds': 15,
            'crossfade': 2.0,
          },
        }),
        'extend');
    report['extend'] = summary(e);
    report['ok'] = e.status == SongStatus.done;
  } catch (err) {
    report['ok'] = false;
    report['error'] = err.toString();
  }
  report['finished'] = DateTime.now().toIso8601String();
  await Directory(reportDir).create(recursive: true);
  await File(p.join(reportDir, 'selftest.json')).writeAsString(const JsonEncoder.withIndent('  ').convert(report));
  if (Platform.environment['STUDIO_SELFTEST_QUIT'] == '1') {
    await studio.engine?.shutdown();
    exit(report['ok'] == true ? 0 : 1);
  }
}
