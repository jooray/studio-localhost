import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'song.dart';

/// Read-only view of song folders in the older YuE2 layouts (mlx-yue output folders and
/// YuE2 Studio 0.1: audio.flac + semantic.npy + request.json/result.json/studio.json).
Song? loadLegacyYue2(String dir) {
  final audio = File(p.join(dir, 'audio.flac'));
  if (!audio.existsSync()) return null;
  Map<String, dynamic> readJson(String name) {
    try {
      final f = File(p.join(dir, name));
      if (f.existsSync()) return Map<String, dynamic>.from(jsonDecode(f.readAsStringSync()) as Map);
    } catch (_) {}
    return {};
  }

  final result = readJson('result.json');
  final request = readJson('request.json');
  final config = readJson('config.json');
  final studio = readJson('studio.json');
  final params = Map<String, dynamic>.from(studio['params'] as Map? ?? {});
  final gen = config['generation'];
  final created = studio['created'] as String? ?? audio.lastModifiedSync().toIso8601String();
  final meta = <String, dynamic>{
    'format': Song.format,
    'version': Song.formatVersion,
    'id': p.basename(dir),
    'title': (studio['title'] as String?) ?? (request['id'] is String && request['id'] != 'song' ? request['id'] : p.basename(dir)),
    'created': created,
    'kind': studio['kind'] ?? 'generate',
    'status': 'done',
    'model': {'id': 'yue2-3b', 'licence': 'CC-BY-NC-4.0', 'format': 'mlx'},
    'engine': {'id': studio['backend'] == 'yue2cpp' ? 'sidecar-yue2cpp' : 'sidecar-mlx'},
    'params': {
      'style': request['style'] ?? '',
      'lyrics': request['lyrics'] ?? '',
      'mode': request['cot'] ?? '',
      'seed': request['seed'] ?? request['lm_seed'],
      'steps': params['steps'] ?? (gen is Map ? gen['ode_steps'] : null) ?? config['steps'],
      'precision': params['precision'] ?? config['ar_precision'],
      'instrumental': params['instrumental'] == true,
      if (params['max_seconds'] != null) 'max_seconds': params['max_seconds'],
    },
    'audio': 'audio.flac',
    if (File(p.join(dir, 'render.flac')).existsSync()) 'render': 'render.flac',
    'audio_seconds': result['audio_seconds'],
    'truncated': result['truncated'],
    'engine_timing': result['timing'],
    if (studio['section'] != null) 'section': studio['section'],
    if (studio['seam'] != null) 'seam': studio['seam'],
  };
  return Song(dir, meta, readOnly: true, legacy: true);
}
