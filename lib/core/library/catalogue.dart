import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Catalogue numbers: every song gets a sequential number (LRS-001, LRS-002, ...) the first time
/// the library sees it, oldest first. Numbers are never reused, also after a song is deleted.
/// Kept in `catalogue.json` in the data dir (own songs also carry theirs in song.json).
class Catalogue {
  Catalogue(this.file);

  final String file;
  int _next = 1;
  final Map<String, int> _byDir = {};
  bool _loaded = false;

  static const prefix = 'LRS';

  static String format(int? n) => n == null ? '$prefix-···' : '$prefix-${n.toString().padLeft(3, '0')}';

  /// The bare number as shown in the index ("015").
  static String short(int? n) => n == null ? '···' : n.toString().padLeft(3, '0');

  int get next => _next;

  int? of(String dir) => _byDir[dir];

  void _load() {
    if (_loaded) return;
    _loaded = true;
    try {
      final f = File(file);
      if (!f.existsSync()) return;
      final j = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
      _next = (j['next'] as num?)?.toInt() ?? 1;
      final m = j['entries'];
      if (m is Map) {
        for (final e in m.entries) {
          if (e.value is num) _byDir[e.key as String] = (e.value as num).toInt();
        }
      }
    } catch (_) {}
  }

  /// Give numbers to songs that have none yet. [songs] are (dir, created, own number from
  /// song.json). Returns true when something changed.
  bool assign(Iterable<(String dir, DateTime created, int? own)> songs) {
    _load();
    var changed = false;
    final sorted = songs.toList()..sort((a, b) => a.$2.compareTo(b.$2));
    // Numbers a song already carries come first, so new ones never collide with them.
    for (final (dir, _, own) in sorted) {
      if (own == null || _byDir.containsKey(dir)) continue;
      _byDir[dir] = own;
      if (own >= _next) _next = own + 1;
      changed = true;
    }
    for (final (dir, _, _) in sorted) {
      if (_byDir.containsKey(dir)) continue;
      _byDir[dir] = _next++;
      changed = true;
    }
    if (changed) save();
    return changed;
  }

  /// Reserve the next number for a new song folder.
  int reserve(String dir) {
    _load();
    final n = _next++;
    _byDir[dir] = n;
    save();
    return n;
  }

  void save() {
    try {
      final f = File(file);
      f.parent.createSync(recursive: true);
      final tmp = File('$file.tmp');
      tmp.writeAsStringSync(const JsonEncoder.withIndent('  ').convert({'next': _next, 'entries': _byDir}));
      tmp.renameSync(f.path);
    } catch (_) {}
  }

  static String fileIn(String dataDir) => p.join(dataDir, 'catalogue.json');
}

/// One block of a song's colour code strip. [colour]: 0 grey, 1 blue, 2 gold, 3 red, 4 off-white.
class CodeBlock {
  const CodeBlock(this.colour, this.weight);
  final int colour;
  final int weight;
}

/// The five-block colour code of a song, derived from its seed: the order of the five colours and
/// each block's width (1 or 2 units) are deterministic, so each song's strip is its signature.
List<CodeBlock> codeStrip(int seed) {
  var x = seed & 0x7fffffffffffffff;
  int nextRand() {
    // splitmix64, kept to 62 bits so it stays a positive Dart int
    x = (x + 0x1e3779b97f4a7c15) & 0x3fffffffffffffff;
    var z = x;
    z = ((z ^ (z >> 30)) * 0x3f58476d1ce4e5b9) & 0x3fffffffffffffff;
    z = ((z ^ (z >> 27)) * 0x14d049bb133111eb) & 0x3fffffffffffffff;
    return (z ^ (z >> 31)) & 0x3fffffffffffffff;
  }

  final order = [0, 1, 2, 3, 4];
  for (var i = order.length - 1; i > 0; i--) {
    final j = nextRand() % (i + 1);
    final t = order[i];
    order[i] = order[j];
    order[j] = t;
  }
  return [for (final c in order) CodeBlock(c, nextRand() % 4 == 0 ? 2 : 1)];
}

/// A stable seed for songs that have none recorded (imported folders).
int seedFromText(String s) {
  var h = 0x811c9dc5;
  for (final c in s.codeUnits) {
    h = ((h ^ c) * 0x01000193) & 0xffffffff;
  }
  return h;
}
