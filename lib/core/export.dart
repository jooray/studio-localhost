import 'dart:io';

import 'package:path/path.dart' as p;

import 'engine/sidecar_engine.dart';
import 'library/song.dart';
import 'paths.dart';
import 'platform/android_bridge.dart';
import 'settings.dart';
import 'studio.dart';

/// Export a song to another format (desktop) or hand it to the share sheet (Android).
class Exporter {
  Exporter(this.studio);

  final Studio studio;
  Settings get settings => studio.settings;

  /// Formats offered for this platform.
  List<String> get formats => Platform.isAndroid ? const ['mp3', 'wav'] : const ['mp3', 'flac', 'wav'];

  String suggestedName(Song s, String fmt) => '${s.title.replaceAll(RegExp(r'[/\\:*?"<>|]'), '_')}.$fmt';

  /// Desktop: write the song as [fmt] to [destination].
  Future<void> exportTo(Song s, String fmt, String destination) async {
    final src = s.audioPath!;
    if (p.extension(src) == '.$fmt') {
      await File(src).copy(destination);
      return;
    }
    final ffmpeg = AppPaths.ffmpeg(settings.ffmpegPath);
    if (ffmpeg != null) {
      final codec = switch (fmt) {
        'mp3' => ['-codec:a', 'libmp3lame', '-b:a', '256k'],
        'flac' => ['-codec:a', 'flac'],
        _ => ['-codec:a', 'pcm_s24le'],
      };
      final r = await Process.run(ffmpeg, ['-hide_banner', '-loglevel', 'error', '-y', '-i', src, ...codec, destination]);
      if (r.exitCode != 0) throw Exception(r.stderr);
      return;
    }
    final e = studio.engine;
    if (e is SidecarEngine) {
      await e.request('export', {'source': src, 'destination': destination, 'format': fmt});
      return;
    }
    throw Exception('No converter available (install ffmpeg)');
  }

  /// Android: open the share sheet for the song as [fmt] (mp3 as stored, wav converted).
  Future<void> share(Song s, {String fmt = 'mp3'}) async {
    var path = s.audioPath!;
    if (p.extension(path) != '.$fmt') {
      final out = p.join(s.dir, 'work', 'share.$fmt');
      await AndroidBridge.call('convertAudio', {'src': path, 'dst': out});
      path = out;
    }
    await AndroidBridge.call('share', {
      'path': path,
      'mime': fmt == 'wav' ? 'audio/wav' : (fmt == 'flac' ? 'audio/flac' : 'audio/mpeg'),
      'title': s.title,
    });
  }
}
