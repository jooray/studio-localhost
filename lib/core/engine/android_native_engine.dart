import 'dart:async';

import '../library/song.dart';
import '../platform/android_bridge.dart';
import 'engine.dart';

/// Android engine: yue2.cpp in-process (JNI) inside a foreground service. The service keeps its
/// own queue (songs with status "queued", oldest queued_at first), writes song.json itself and
/// resumes from checkpoints after the process was killed.
class AndroidNativeEngine extends Engine {
  AndroidNativeEngine(this.descriptor) {
    _sub = AndroidBridge.events.listen(_onEvent);
  }

  @override
  final EngineDescriptor descriptor;
  late final StreamSubscription _sub;
  final _events = StreamController<EngineEvent>.broadcast();
  String? _running;

  @override
  Stream<EngineEvent> get events => _events.stream;

  @override
  bool get ownsQueue => true;

  @override
  bool get writesSongMetadata => true;

  @override
  bool get busy => _running != null;

  @override
  String get statusText => _running == null ? 'Ready' : 'Working';

  @override
  Future<void> warmUp() async {
    try {
      await AndroidBridge.call('recover');
      final s = await AndroidBridge.map('status');
      _running = s['running'] as String?;
      notifyListeners();
    } catch (_) {}
  }

  @override
  Future<Map<String, dynamic>> info() => AndroidBridge.map('deviceInfo');

  @override
  Future<void> run(Song song, JobContext ctx) async {
    // song.json carries model.files ({role: path}); the service reads everything from there.
    await AndroidBridge.call('requestNotifications');
    await AndroidBridge.call('enqueue', {'dir': song.dir});
  }

  @override
  Future<void> cancel(Song song) => AndroidBridge.call('cancel', {'id': song.id, 'dir': song.dir});

  void _onEvent(Map<String, dynamic> e) {
    switch (e['type']) {
      case 'progress':
        _running = e['id'] as String?;
        _events.add(EngineProgress(
          e['id'] as String? ?? '',
          stage: e['stage'] as String? ?? '',
          label: e['label'] as String? ?? '',
          done: (e['done'] as num?)?.toInt(),
          total: (e['total'] as num?)?.toInt(),
          unit: e['unit'] as String?,
          elapsed: (e['elapsed'] as num?)?.toDouble(),
        ));
      case 'job':
        final status = parseStatus(e['status'] as String?);
        if (status == SongStatus.running) {
          _running = e['id'] as String?;
        } else {
          if (_running == e['id']) _running = null;
          _events.add(EngineJobEnded(e['id'] as String? ?? '', status, error: e['error'] as String?));
        }
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _sub.cancel();
    _events.close();
    super.dispose();
  }
}
