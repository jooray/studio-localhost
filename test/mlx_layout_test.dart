import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:studio_localhost/core/engine/sidecar_runtimes.dart';
import 'package:studio_localhost/core/models/registry.dart';
import 'package:studio_localhost/core/paths.dart';
import 'package:studio_localhost/core/settings.dart';

// AppPaths reads STUDIO_DATA_DIR. Without it the test would touch the real app folder, so it skips.
final _scratch = Platform.environment['STUDIO_DATA_DIR'];
final Object _skip = (_scratch ?? '').isEmpty ? 'set STUDIO_DATA_DIR to a scratch folder' : false;

void main() {
  late Directory data;
  late MlxRuntime rt;
  final registry = ModelRegistry.fromJson(
      jsonDecode(File('assets/models/registry.json').readAsStringSync()) as Map<String, dynamic>);
  final m = registry.models.first;
  final f = m.formats.firstWhere((x) => x.id == 'mlx');

  setUpAll(() async {
    if (_skip != false) return;
    data = Directory(p.join(_scratch!, 'layout-test'))..createSync(recursive: true);
    await AppPaths.init();
    rt = MlxRuntime(Settings(p.join(data.path, 'settings.json')));
  });

  Set<String> missing() =>
      {for (final e in rt.requiredFiles(m, f, f.variants.first).entries) if (!File(e.value).existsSync()) e.key};

  void touch(String path) => File(path)
    ..parent.createSync(recursive: true)
    ..writeAsStringSync('x');

  test('both AR precisions are required for every variant', () {
    for (final v in f.variants) {
      expect(v.patterns, containsAll(['ar-8bit.safetensors', 'ar-bf16.safetensors', 'nar-bf16.safetensors']));
    }
  });

  test('0.4.4 layout needs setup; the repaired layout is ready', skip: _skip, () {
    final root = rt.modelRoot(m, f);
    if (Directory(root).existsSync()) Directory(root).deleteSync(recursive: true);
    // 0.4.4: everything flat in root, vae/ inside, a .cache tree, one AR precision.
    for (final n in ['conversion.json', 'ar-8bit.safetensors', 'nar-bf16.safetensors', 'vae/model.safetensors',
      '.cache/huggingface/CACHEDIR.TAG']) {
      touch(p.join(root, n));
    }
    expect(rt.modelDir(m, f), p.join(root, 'mlx-Yue2-3B'));
    expect(rt.vaeDir(m, f), p.join(root, 'vae'));
    expect(missing(), containsAll(['ar-8bit.safetensors', 'ar-bf16.safetensors', 'conversion.json', 'verification']));

    final model = p.join(root, 'mlx-Yue2-3B');
    for (final n in ['conversion.json', 'ar-8bit.safetensors', 'ar-bf16.safetensors', 'nar-bf16.safetensors']) {
      touch(p.join(model, n));
    }
    expect(missing(), {'verification'});
    touch(rt.verifiedMarker(m, f));
    expect(missing(), isEmpty);
    Directory(root).deleteSync(recursive: true);
  });
}
