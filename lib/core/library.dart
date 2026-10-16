import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'paths.dart';
import 'settings.dart';

/// One song folder: mlx-yue artifacts (audio.flac, result.json, request.json, config.json,
/// semantic.npy, score.abc) plus studio.json when YuE2 Studio made it.
class Song {
  Song(this.dir, {required this.readOnly});

  final String dir;
  final bool readOnly;
  Map<String, dynamic> result = {};
  Map<String, dynamic> request = {};
  Map<String, dynamic> config = {};
  Map<String, dynamic> studio = {};
  String? abc;
  DateTime modified = DateTime.fromMillisecondsSinceEpoch(0);

  String get audioPath => p.join(dir, 'audio.flac');
  String? get renderPath => File(p.join(dir, 'render.flac')).existsSync() ? p.join(dir, 'render.flac') : null;
  bool get hasSemantic => File(p.join(dir, 'semantic.npy')).existsSync();
  String get title {
    final t = studio['title'];
    if (t is String && t.trim().isNotEmpty) return t.trim();
    final id = request['id'];
    if (id is String && id != 'song') return id;
    return p.basename(dir);
  }

  String get kind => (studio['kind'] as String?) ?? 'mlx-yue';
  String get backend => (studio['backend'] as String?) ?? (config['backend'] as String?) ?? 'mlx';
  double get seconds => (result['audio_seconds'] as num?)?.toDouble() ?? 0;
  String get style => (request['style'] as String?) ?? '';
  String get lyrics => (request['lyrics'] as String?) ?? '';
  String get cot => (request['cot'] as String?) ?? '?';
  int? get seed => (request['seed'] as num?)?.toInt() ?? (request['lm_seed'] as num?)?.toInt();
  Map<String, dynamic> get params => Map<String, dynamic>.from(studio['params'] as Map? ?? {});
  Map<String, dynamic> get timing => Map<String, dynamic>.from(result['timing'] as Map? ?? {});

  int? get steps {
    final s = params['steps'];
    if (s is num) return s.toInt();
    final g = config['generation'];
    if (g is Map && g['ode_steps'] is num) return (g['ode_steps'] as num).toInt();
    if (config['steps'] is num) return (config['steps'] as num).toInt();
    return null;
  }

  String? get precision {
    final s = params['precision'];
    if (s is String) return s;
    return config['ar_precision'] as String?;
  }

  bool get instrumental => params['instrumental'] == true || style.toLowerCase().contains('no vocals');

  Map<String, bool> get truncated {
    final t = result['truncated'];
    if (t is Map) return {for (final e in t.entries) e.key.toString(): e.value == true};
    return {};
  }

  /// True when the semantic stage hit a length cap the user asked for (not an accident).
  bool get stoppedAtRequestedLength {
    final max = params['max_seconds'] ?? params['add_seconds'];
    return truncated['semantic'] == true && max is num && max > 0;
  }

  bool get truncationWarning =>
      truncated['abc'] == true || (truncated['semantic'] == true && !stoppedAtRequestedLength);

  static Song? load(String dir, {required bool readOnly}) {
    final audio = File(p.join(dir, 'audio.flac'));
    if (!audio.existsSync()) return null;
    final s = Song(dir, readOnly: readOnly);
    Map<String, dynamic> readJson(String name) {
      try {
        final f = File(p.join(dir, name));
        if (f.existsSync()) return Map<String, dynamic>.from(jsonDecode(f.readAsStringSync()) as Map);
      } catch (_) {}
      return {};
    }

    s.result = readJson('result.json');
    s.request = readJson('request.json');
    s.config = readJson('config.json');
    s.studio = readJson('studio.json');
    try {
      final abc = File(p.join(dir, 'score.abc'));
      if (abc.existsSync()) s.abc = abc.readAsStringSync();
    } catch (_) {}
    if (s.request['abc'] is String && s.abc == null) s.abc = s.request['abc'] as String;
    s.modified = audio.lastModifiedSync();
    final created = DateTime.tryParse((s.studio['created'] as String?) ?? '');
    if (created != null) s.modified = created.toLocal();
    return s;
  }
}

class Library extends ChangeNotifier {
  Library(this.settings, this.paths);

  final Settings settings;
  final AppPaths paths;
  List<Song> songs = [];

  Future<void> refresh() async {
    final found = <Song>[];
    final hidden = settings.hiddenSongs.toSet();
    void scan(String root, bool readOnly) {
      final d = Directory(root);
      if (!d.existsSync()) return;
      for (final e in d.listSync(followLinks: false)) {
        if (e is! Directory || hidden.contains(e.path)) continue;
        final s = Song.load(e.path, readOnly: readOnly);
        if (s != null) found.add(s);
      }
    }

    scan(paths.libraryDir, false);
    for (final root in settings.importRoots) {
      scan(root, true);
    }
    found.sort((a, b) => b.modified.compareTo(a.modified));
    songs = found;
    notifyListeners();
  }

  Song? byDir(String dir) {
    for (final s in songs) {
      if (s.dir == dir) return s;
    }
    return null;
  }

  /// A fresh, unique folder under the app library.
  String newSongDir(String title) {
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final stamp = '${now.year}${two(now.month)}${two(now.day)}-${two(now.hour)}${two(now.minute)}${two(now.second)}';
    var slug = title.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '-').replaceAll(RegExp(r'^-+|-+$'), '');
    if (slug.length > 40) slug = slug.substring(0, 40);
    if (slug.isEmpty) slug = 'song';
    var dir = p.join(paths.libraryDir, '$stamp-$slug');
    var i = 2;
    while (Directory(dir).existsSync()) {
      dir = p.join(paths.libraryDir, '$stamp-$slug-$i');
      i++;
    }
    return dir;
  }

  /// Library songs are deleted from disk; imported (read-only) ones are only hidden.
  Future<void> delete(Song s) async {
    if (s.readOnly) {
      settings.hideSong(s.dir);
    } else {
      await Directory(s.dir).delete(recursive: true);
    }
    await refresh();
  }

  Future<void> rename(Song s, String title) async {
    if (s.readOnly) return;
    final f = File(p.join(s.dir, 'studio.json'));
    final data = Map<String, dynamic>.from(s.studio);
    data['title'] = title;
    await f.writeAsString(const JsonEncoder.withIndent('  ').convert(data));
    await refresh();
  }
}
