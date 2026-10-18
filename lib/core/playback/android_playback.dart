import 'dart:async';

import 'package:flutter/services.dart';

import 'playback.dart';

/// Android playback: Media3 ExoPlayer in the app's Kotlin code (AudioPlayerChannel.kt).
/// media_kit is not used on Android: its libmpv maps code from memory (memfd_create + dlopen),
/// which GrapheneOS flags as dynamic code loading.
class AndroidPlayback implements PlaybackBackend {
  AndroidPlayback() {
    _sub = _events.receiveBroadcastStream().listen((e) {
      final m = Map<String, dynamic>.from(e as Map);
      final s = PlaybackState(
        playing: m['playing'] == true,
        position: Duration(milliseconds: (m['position'] as num?)?.toInt() ?? 0),
        duration: Duration(milliseconds: (m['duration'] as num?)?.toInt() ?? 0),
        completed: m['completed'] == true,
        error: m['error'] as String?,
      );
      if (s.position != _last.position) _position.add(s.position);
      if (s.duration != _last.duration) _duration.add(s.duration);
      if (s.playing != _last.playing) _playing.add(s.playing);
      if (s.completed != _last.completed) _completed.add(s.completed);
      if (s.error != null && s.error != _last.error) _error.add(s.error!);
      _last = s;
    });
  }

  static const _method = MethodChannel('studio/player');
  static const _events = EventChannel('studio/player/events');
  StreamSubscription? _sub;
  PlaybackState _last = const PlaybackState();
  final _position = StreamController<Duration>.broadcast();
  final _duration = StreamController<Duration>.broadcast();
  final _playing = StreamController<bool>.broadcast();
  final _completed = StreamController<bool>.broadcast();
  final _error = StreamController<String>.broadcast();

  @override
  Stream<Duration> get position => _position.stream;
  @override
  Stream<Duration> get duration => _duration.stream;
  @override
  Stream<bool> get playing => _playing.stream;
  @override
  Stream<bool> get completed => _completed.stream;
  @override
  Stream<String> get error => _error.stream;

  @override
  Future<void> open(String file) => _method.invokeMethod('open', {'path': file});
  @override
  Future<void> play() => _method.invokeMethod('play');
  @override
  Future<void> pause() => _method.invokeMethod('pause');
  @override
  Future<void> stop() => _method.invokeMethod('stop');
  @override
  Future<void> seek(Duration d) => _method.invokeMethod('seek', {'ms': d.inMilliseconds});
  @override
  Future<void> setVolume(double v) => _method.invokeMethod('volume', {'v': v});

  @override
  Future<void> dispose() async {
    await _sub?.cancel();
    await _method.invokeMethod('dispose');
    for (final c in [_position, _duration, _playing, _completed, _error]) {
      await c.close();
    }
  }
}
