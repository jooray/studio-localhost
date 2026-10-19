import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../audio/envelope.dart';
import '../paths.dart';
import '../platform/android_bridge.dart';
import '../settings.dart';
import 'song.dart';

/// Amplitude envelopes of library songs, the data behind every polar plot. Computed once per song
/// and cached: own songs keep `envelope.json` in their folder; imported (read-only) songs are
/// cached in the app data dir. One file is decoded at a time; listeners hear when one is ready.
class Envelopes extends ChangeNotifier {
  Envelopes(this.settings);

  final Settings settings;
  final Map<String, Envelope?> _done = {};
  final Map<String, Song> _waiting = {};
  final Map<String, Envelope> _pinned = {};
  bool _working = false;

  static const bins = 720;

  /// The envelope of [s] if it is ready; otherwise starts computing it and returns null.
  Envelope? of(Song? s) {
    if (s == null) return null;
    final pinned = _pinned[s.dir];
    if (pinned != null) return pinned;
    final audio = s.audioPath;
    if (audio == null) return null;
    if (_done.containsKey(audio)) return _done[audio];
    _waiting[audio] = s;
    if (!_working) scheduleMicrotask(_work);
    return null;
  }

  /// Use a known envelope for a song folder (demo content, tests).
  void pin(String dir, Envelope e) {
    _pinned[dir] = e;
    notifyListeners();
  }

  /// Forget a song's envelope (its audio changed).
  void forget(Song s) {
    final a = s.audioPath;
    if (a != null) _done.remove(a);
  }

  String cachePathFor(Song s) {
    if (!s.readOnly) return p.join(s.dir, 'envelope.json');
    final key = sha1.convert(s.dir.codeUnits).toString().substring(0, 16);
    return p.join(AppPaths.instance.dataDir, 'cache', 'envelopes', '$key.json');
  }

  Future<void> _work() async {
    if (_working) return;
    _working = true;
    try {
      while (_waiting.isNotEmpty) {
        final audio = _waiting.keys.first;
        final s = _waiting.remove(audio)!;
        Envelope? e;
        try {
          e = await _compute(s, audio);
        } catch (_) {
          e = null;
        }
        _done[audio] = e;
        notifyListeners();
      }
    } finally {
      _working = false;
    }
  }

  Future<Envelope?> _compute(Song s, String audio) async {
    final cache = cachePathFor(s);
    await Directory(p.dirname(cache)).create(recursive: true);
    if (p.extension(audio).toLowerCase() != '.mp3') {
      return loadOrComputeEnvelope(audio, cache, bins: bins);
    }
    // MP3: the cache may already hold it; otherwise decode to a temporary WAV first.
    final cached = File(cache);
    if (cached.existsSync() && cached.lastModifiedSync().isAfter(File(audio).lastModifiedSync())) {
      try {
        final e = Envelope.fromJson(jsonDecode(await cached.readAsString()) as Map<String, dynamic>);
        if (e != null && e.bins == bins) return e;
      } catch (_) {}
    }
    final tmp = p.join(AppPaths.instance.dataDir, 'cache', 'envelope-src.wav');
    await Directory(p.dirname(tmp)).create(recursive: true);
    try {
      if (Platform.isAndroid) {
        await AndroidBridge.call('convertAudio', {'src': audio, 'dst': tmp});
      } else {
        final ffmpeg = AppPaths.ffmpeg(settings.ffmpegPath);
        if (ffmpeg == null) return null;
        final r = await Process.run(ffmpeg, ['-hide_banner', '-loglevel', 'error', '-y', '-i', audio, '-ac', '2', '-ar', '12000', tmp]);
        if (r.exitCode != 0) return null;
      }
      final e = await computeEnvelope(tmp, bins: bins);
      if (e != null) {
        try {
          await File(cache).writeAsString(jsonEncode(e.toJson()));
        } catch (_) {}
      }
      return e;
    } finally {
      try {
        File(tmp).deleteSync();
      } catch (_) {}
    }
  }
}
