import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:studio_localhost/core/setup/uv_bootstrap.dart';

void main() {
  test('uv release asset for this platform is pinned with a checksum', () {
    final t = UvBootstrap.target;
    if (!Platform.isMacOS && !Platform.isLinux) return;
    expect(t, isNotNull);
    expect(UvBootstrap.sha256s[t], matches(RegExp(r'^[0-9a-f]{64}$')));
    expect(UvBootstrap.url(t!).toString(),
        'https://github.com/astral-sh/uv/releases/download/${UvBootstrap.version}/uv-$t.tar.gz');
  });

  // Downloads about 20 MB. Run with STUDIO_NET_TESTS=1.
  test('fetches the pinned standalone uv into the data dir and checks its sha256', () async {
    final dir = await Directory.systemTemp.createTemp('uv-bootstrap');
    try {
      final b = UvBootstrap(dir.path);
      final lines = <String>[];
      final uv = await b.ensure(log: lines.add, system: false);
      expect(uv, p.join(dir.path, 'bin', 'uv'));
      expect(lines.single, contains('uv not found'));
      final r = await Process.run(uv, ['--version']);
      expect(r.stdout as String, startsWith('uv ${UvBootstrap.version}'));
      // A second call reuses the copy instead of downloading again.
      expect(await b.ensure(log: lines.add, system: false), uv);
      expect(lines.length, 1);
    } finally {
      await dir.delete(recursive: true);
    }
  }, skip: Platform.environment['STUDIO_NET_TESTS'] != '1', timeout: const Timeout(Duration(minutes: 3)));
}
