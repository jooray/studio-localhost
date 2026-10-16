import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../app_info.dart';
import '../paths.dart';
import '../settings.dart';
import 'legacy_yue2.dart';
import 'song.dart';

/// The song library: the app's own folder plus read-only imported folders.
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
        final s = Song.load(e.path, readOnly: readOnly) ?? (readOnly ? loadLegacyYue2(e.path) : null);
        if (s != null) found.add(s);
      }
    }

    scan(paths.libraryDir, false);
    for (final root in settings.importRoots) {
      scan(root, true);
    }
    found.sort((a, b) => b.created.compareTo(a.created));
    songs = found;
    notifyListeners();
  }

  Song? byId(String? id) {
    for (final s in songs) {
      if (s.id == id) return s;
    }
    return null;
  }

  Song? byDir(String? dir) {
    for (final s in songs) {
      if (s.dir == dir) return s;
    }
    return null;
  }

  /// Read one song fresh from disk (the Android engine updates song.json while it runs).
  Song? reload(Song s) => Song.load(s.dir, readOnly: s.readOnly) ?? s;

  List<Song> get queued {
    final q = songs.where((s) => s.status == SongStatus.queued).toList();
    q.sort((a, b) => (a.queuedAt ?? a.created).compareTo(b.queuedAt ?? b.created));
    return q;
  }

  List<Song> children(Song s) => songs.where((c) => c.parentId == s.id).toList();

  List<Song> lineage(Song s) {
    final out = <Song>[];
    var cur = byId(s.parentId);
    while (cur != null && out.length < 32) {
      out.add(cur);
      cur = byId(cur.parentId);
    }
    return out;
  }

  String _newDir(String title) {
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

  /// Create a queued song folder with its song.json. [fields] carry kind, params, model, engine...
  Future<Song> create(String title, Map<String, dynamic> fields) async {
    final dir = _newDir(title);
    await Directory(p.join(dir, 'work')).create(recursive: true);
    final now = DateTime.now().toIso8601String();
    final meta = <String, dynamic>{
      'format': Song.format,
      'version': Song.formatVersion,
      'id': p.basename(dir),
      'title': title,
      'created': now,
      'queued_at': now,
      'status': SongStatus.queued.name,
      'app': {'name': appName, 'version': appVersion},
      ...fields,
    };
    await _write(dir, meta);
    final song = Song(dir, meta);
    songs = [song, ...songs];
    notifyListeners();
    return song;
  }

  /// Merge [changes] into song.json as it is on disk (top-level keys; null removes a key).
  Future<Song> patch(Song s, Map<String, dynamic> changes) async {
    if (s.readOnly) return s;
    final fresh = Song.load(s.dir)?.meta ?? Map<String, dynamic>.from(s.meta);
    for (final e in changes.entries) {
      if (e.value == null) {
        fresh.remove(e.key);
      } else {
        fresh[e.key] = e.value;
      }
    }
    await _write(s.dir, fresh);
    final updated = Song(s.dir, fresh);
    songs = [for (final x in songs) x.dir == s.dir ? updated : x];
    notifyListeners();
    return updated;
  }

  Future<void> _write(String dir, Map<String, dynamic> meta) async {
    final f = File(p.join(dir, 'song.json'));
    final tmp = File(p.join(dir, 'song.json.tmp'));
    await tmp.writeAsString(const JsonEncoder.withIndent('  ').convert(meta));
    await tmp.rename(f.path);
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
    await patch(s, {'title': title});
  }
}
