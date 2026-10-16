import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';

/// One shared audio player (media_kit / libmpv on every platform).
class AudioPlayerModel extends ChangeNotifier {
  AudioPlayerModel() {
    _subs.addAll([
      _player.stream.position.listen((v) {
        position = v;
        notifyListeners();
      }),
      _player.stream.duration.listen((v) {
        duration = v;
        notifyListeners();
      }),
      _player.stream.playing.listen((v) {
        playing = v;
        notifyListeners();
      }),
      _player.stream.completed.listen((v) {
        if (v) {
          playing = false;
          notifyListeners();
        }
      }),
      _player.stream.error.listen((e) {
        error = e;
        notifyListeners();
      }),
    ]);
  }

  final Player _player = Player(configuration: const PlayerConfiguration(title: 'Localhost Recording Studio'));
  final List<StreamSubscription> _subs = [];
  String? path;
  String? title;
  Duration position = Duration.zero;
  Duration duration = Duration.zero;
  bool playing = false;
  String? error;

  Future<void> play(String file, {String? title}) async {
    error = null;
    if (path != file) {
      path = file;
      this.title = title;
      await _player.open(Media(Uri.file(file).toString()), play: true);
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
