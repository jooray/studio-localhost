import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:studio_localhost/core/app_info.dart';
import 'package:studio_localhost/core/engine/engines.dart';
import 'package:studio_localhost/core/engine/hardware.dart';
import 'package:studio_localhost/core/library/song.dart';
import 'package:studio_localhost/core/models/registry.dart';

void main() {
  test('compareVersions', () {
    expect(compareVersions('0.10.0', '0.9.9') > 0, isTrue);
    expect(compareVersions(appVersion, appVersion), 0);
    expect(compareVersions('v0.3.0', '0.3.0'), 0);
    expect(compareVersions('0.2.9', appVersion) < 0, isTrue);
  });

  final registry = ModelRegistry.fromJson(
      jsonDecode(File('assets/models/registry.json').readAsStringSync()) as Map<String, dynamic>);

  test('registry: every model has a licence, limits and a format per engine', () {
    expect(registry.models, isNotEmpty);
    for (final m in registry.models) {
      expect(m.licence.spdx, isNotEmpty);
      expect(m.licence.url, startsWith('https://'));
      expect(m.limits.maxSeconds, greaterThan(0));
      for (final f in m.formats) {
        expect(f.variants, isNotEmpty);
        for (final v in f.variants) {
          expect(v.bytes, greaterThan(0));
          for (final file in v.files) {
            expect(file.sha256.length, 64);
          }
        }
      }
    }
  });

  test('engine selection follows hardware, overridable', () {
    final m = registry.models.first;
    const mac = Hardware(os: 'macos', arch: 'arm64', appleSilicon: true, description: '');
    const intelMac = Hardware(os: 'macos', arch: 'x86_64', description: '');
    const linux = Hardware(os: 'linux', arch: 'x86_64', description: '');
    const android = Hardware(os: 'android', arch: 'arm64-v8a', description: '');
    expect(selectEngine(mac, model: m)!.id, 'sidecar-mlx');
    expect(selectEngine(mac, model: m, override: 'sidecar-yue2cpp')!.id, 'sidecar-yue2cpp');
    expect(selectEngine(intelMac, model: m)!.id, 'sidecar-yue2cpp');
    expect(selectEngine(intelMac, model: m, override: 'sidecar-mlx')!.id, 'sidecar-yue2cpp');
    expect(selectEngine(linux, model: m)!.id, 'sidecar-yue2cpp');
    expect(selectEngine(android, model: m)!.id, 'android-native');
    expect(m.formatFor('android-native')!.defaultVariant('android-native').id, 'Q6_K');
  });

  test('song.json round trip', () {
    final dir = Directory.systemTemp.createTempSync('song');
    File('${dir.path}/song.json').writeAsStringSync(jsonEncode({
      'format': Song.format,
      'version': Song.formatVersion,
      'id': 'x',
      'title': 'T',
      'status': 'interrupted',
      'kind': 'extend',
      'model': {'id': 'm', 'licence': 'L'},
      'params': {'seed': 3, 'steps': 8, 'max_seconds': 20},
      'truncated': {'semantic': true},
    }));
    final s = Song.load(dir.path)!;
    expect(s.status, SongStatus.interrupted);
    expect(s.resumable, isTrue);
    expect(s.licenceId, 'L');
    expect(s.stoppedAtRequestedLength, isTrue);
    expect(s.truncationWarning, isFalse);
    dir.deleteSync(recursive: true);
  });
}
