import 'dart:async';

import 'package:flutter/services.dart';

/// Platform channels to the Android host (MainActivity). Only used when running on Android.
///
/// Method channel `studio/native`: paths, deviceInfo, enqueue, cancel, status, recover, download,
/// cancelDownload, modelFiles, deleteFile, share, convertAudio, freeBytes, requestNotifications.
/// Event channel `studio/events`: maps with a `type` of `progress`, `job` or `download`.
class AndroidBridge {
  AndroidBridge._();

  static const _method = MethodChannel('studio/native');
  static const _events = EventChannel('studio/events');
  static Stream<Map<String, dynamic>>? _stream;

  static Stream<Map<String, dynamic>> get events =>
      _stream ??= _events.receiveBroadcastStream().map((e) => Map<String, dynamic>.from(e as Map)).asBroadcastStream();

  static Future<T?> call<T>(String method, [Map<String, dynamic>? args]) => _method.invokeMethod<T>(method, args);

  static Future<Map<String, dynamic>> map(String method, [Map<String, dynamic>? args]) async {
    final r = await _method.invokeMethod<Map>(method, args);
    return Map<String, dynamic>.from(r ?? const {});
  }

  static Future<List<Map<String, dynamic>>> list(String method, [Map<String, dynamic>? args]) async {
    final r = await _method.invokeMethod<List>(method, args);
    return [for (final e in r ?? const []) Map<String, dynamic>.from(e as Map)];
  }
}
