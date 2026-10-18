import 'dart:io';

import 'android_playback.dart';
import 'media_kit_playback.dart';

/// The state a [PlaybackBackend] reports.
class PlaybackState {
  const PlaybackState({
    this.playing = false,
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.completed = false,
    this.error,
  });

  final bool playing;
  final Duration position;
  final Duration duration;
  final bool completed;
  final String? error;
}

/// Plays one local audio file (FLAC, MP3, WAV) at a time.
/// Android: Media3 ExoPlayer over a platform channel (no native libraries in the APK).
/// macOS and Linux: media_kit (libmpv).
abstract class PlaybackBackend {
  static PlaybackBackend create() => Platform.isAndroid ? AndroidPlayback() : MediaKitPlayback();

  /// Process-wide setup before the first player (media_kit needs it on desktop).
  static void ensureInitialized() {
    if (!Platform.isAndroid) MediaKitPlayback.ensureInitialized();
  }

  Stream<Duration> get position;
  Stream<Duration> get duration;
  Stream<bool> get playing;
  Stream<bool> get completed;
  Stream<String> get error;

  /// Load [file] and start playing it.
  Future<void> open(String file);
  Future<void> play();
  Future<void> pause();
  Future<void> stop();
  Future<void> seek(Duration d);

  /// 0..1
  Future<void> setVolume(double v);
  Future<void> dispose();
}
