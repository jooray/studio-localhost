import 'dart:async';

import 'package:flutter/foundation.dart';
import 'playback/playback.dart';

/// One shared audio player. The backend is Media3 on Android and media_kit on desktop
/// (see [PlaybackBackend]).
class AudioPlayerModel extends ChangeNotifier {
  AudioPlayerModel() {
    _subs.addAll([
      _player.position.listen((v) {
        position = v;
        notifyListeners();
      }),
      _player.duration.listen((v) {
        duration = v;
        notifyListeners();
      }),
      _player.playing.listen((v) {
        playing = v;
        notifyListeners();
      }),
      _player.completed.listen((v) {
        if (v) {
          playing = false;
          notifyListeners();
        }
      }),
      _player.error.listen((e) {
        error = e;
        notifyListeners();
      }),
    ]);
  }

  final PlaybackBackend _player = PlaybackBackend.create();
  final List<StreamSubscription> _subs = [];
  String? path;
  String? title;
  Duration position = Duration.zero;
  Duration duration = Duration.zero;
  bool playing = false;
  String? error;

  /// Called when a file actually starts (a new open, not a resume): the app marks the song played.
  void Function(String path)? onPlay;

  Future<void> play(String file, {String? title}) async {
    error = null;
    if (path != file) {
      path = file;
      this.title = title;
      await _player.open(file);
      onPlay?.call(file);
    } else {
      await _player.play();
    }
    notifyListeners();
  }

  Future<void> toggle(String file, {String? title}) async {
    if (path == file && playing) {
      await _player.pause();
    } else {
      await play(file, title: title);
    }
  }

  Future<void> pause() => _player.pause();
  /// 0..1
  Future<void> setVolume(double v) => _player.setVolume(v);
  Future<void> seek(Duration d) => _player.seek(d);

  Future<void> stopIf(String dirPrefix) async {
    if (path != null && path!.startsWith(dirPrefix)) {
      await _player.stop();
      path = null;
      title = null;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    _player.dispose();
    super.dispose();
  }
}
