import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../paths.dart';

/// uv for the desktop setup. A uv already on the machine wins; otherwise the app fetches the
/// official standalone binary for this platform from the astral-sh/uv GitHub release (pinned
/// version, published sha256 checked) into its own data dir. Nothing is installed system-wide.
class UvBootstrap {
  UvBootstrap(this.dataDir);

  final String dataDir;

  static const version = '0.13.1';

  /// From the release's `uv-<target>.tar.gz.sha256` files.
  static const sha256s = {
    'aarch64-apple-darwin': 'cfe454573412ff7380d15fc7dae5997ab53ffce72fce0a78e91ddbc84001acd2',
    'x86_64-apple-darwin': 'bb7b805bdcf3d0bc8c74ceb94569e6b3e8aa35bd492acdbb9d46bf46d9d4ff6b',
    'aarch64-unknown-linux-gnu': '9041c73c99fdc5892cf128140beb354eca9231d502068cc36e6cb53a8e59ad14',
    'x86_64-unknown-linux-gnu': 'eadd9d27c134ab5ac1ffd4473b97a741407f3ea238288f03121fc4deddf90220',
  };

  static String? get target => switch (Abi.current()) {
        Abi.macosArm64 => 'aarch64-apple-darwin',
        Abi.macosX64 => 'x86_64-apple-darwin',
        Abi.linuxArm64 => 'aarch64-unknown-linux-gnu',
        Abi.linuxX64 => 'x86_64-unknown-linux-gnu',
        _ => null,
      };

  String get binDir => p.join(dataDir, 'bin');
  String get ownUv => p.join(binDir, 'uv');

  static Uri url(String target) =>
      Uri.parse('https://github.com/astral-sh/uv/releases/download/$version/uv-$target.tar.gz');

  /// uv on PATH or in the usual spots (~/.local/bin, /opt/homebrew/bin, /usr/local/bin), then the
  /// app's own copy.
  String? find({bool system = true}) {
    if (system) {
      final s = AppPaths.which('uv');
      if (s != null) return s;
    }
    return File(ownUv).existsSync() ? ownUv : null;
  }

  /// Return a usable uv, downloading the pinned standalone binary if there is none.
  Future<String> ensure({void Function(String)? log, bool system = true}) async {
    final found = find(system: system);
    if (found != null) return found;
    final t = target;
    if (t == null) throw StateError('No standalone uv for this platform (${Abi.current()}). Install uv yourself.');
    log?.call('uv not found; fetching uv $version for this app only into $binDir');
    await Directory(binDir).create(recursive: true);
    final work = Directory(p.join(binDir, '.uv-$version'));
    if (work.existsSync()) await work.delete(recursive: true);
    await work.create();
    try {
      final archive = File(p.join(work.path, 'uv.tar.gz'));
      await _download(url(t), archive);
      final digest = (await sha256.bind(archive.openRead()).first).toString();
      if (digest != sha256s[t]) {
        throw StateError('uv download checksum mismatch ($digest); nothing was installed.');
      }
      final r = await Process.run('tar', ['-xzf', archive.path, '-C', work.path]);
      if (r.exitCode != 0) throw StateError('Could not unpack uv: ${r.stderr}');
      for (final name in ['uv', 'uvx']) {
        final f = File(p.join(work.path, 'uv-$t', name));
        if (!f.existsSync()) continue;
        await Process.run('chmod', ['755', f.path]);
        await f.rename(p.join(binDir, name));
      }
    } finally {
      if (work.existsSync()) await work.delete(recursive: true);
    }
    if (!File(ownUv).existsSync()) throw StateError('uv archive did not contain the uv binary.');
    return ownUv;
  }

  static Future<void> _download(Uri uri, File out) async {
    final client = HttpClient()..userAgent = 'localhost-recording-studio';
    try {
      final res = await (await client.getUrl(uri)).close();
      if (res.statusCode != 200) throw StateError('uv download: HTTP ${res.statusCode}');
      await res.pipe(out.openWrite());
    } finally {
      client.close(force: true);
    }
  }
}
