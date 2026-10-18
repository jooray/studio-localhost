import 'package:media_kit/media_kit.dart';

import 'playback.dart';

/// Desktop playback through media_kit / libmpv.
class MediaKitPlayback implements PlaybackBackend {
  static void ensureInitialized() => MediaKit.ensureInitialized();

  final Player _player = Player(configuration: const PlayerConfiguration(title: 'Localhost Recording Studio'));

  @override
  Stream<Duration> get position => _player.stream.position;
  @override
  Stream<Duration> get duration => _player.stream.duration;
  @override
  Stream<bool> get playing => _player.stream.playing;
  @override
  Stream<bool> get completed => _player.stream.completed;
  @override
  Stream<String> get error => _player.stream.error;

  @override
  Future<void> open(String file) => _player.open(Media(Uri.file(file).toString()), play: true);
  @override
  Future<void> play() => _player.play();
  @override
  Future<void> pause() => _player.pause();
  @override
  Future<void> stop() => _player.stop();
  @override
  Future<void> seek(Duration d) => _player.seek(d);
  @override
  Future<void> setVolume(double v) => _player.setVolume(v * 100);
  @override
  Future<void> dispose() => _player.dispose();
}
