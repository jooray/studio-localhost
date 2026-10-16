import 'dart:io';

import '../platform/android_bridge.dart';

/// What the app runs on. Engine choice uses these facts, not the OS name alone.
class Hardware {
  const Hardware({required this.os, required this.arch, required this.description, this.appleSilicon = false, this.extra = const {}});

  final String os; // android, macos, linux, other
  final String arch; // arm64, x86_64, ...
  final bool appleSilicon;
  final String description;
  final Map<String, dynamic> extra;

  /// Host keys used by EngineDescriptor.hosts.
  List<String> get hostKeys => [
        os,
        if (os == 'macos' && appleSilicon) 'macos-arm64',
      ];

  static Hardware? _cached;

  static Future<Hardware> detect() async {
    if (_cached != null) return _cached!;
    Hardware h;
    if (Platform.isAndroid) {
      Map<String, dynamic> info = {};
      try {
        info = await AndroidBridge.map('deviceInfo');
      } catch (_) {}
      h = Hardware(
        os: 'android',
        arch: info['abi'] as String? ?? 'arm64-v8a',
        description: '${info['model'] ?? 'Android device'} · ${info['cpu'] ?? ''}'.trim(),
        extra: info,
      );
    } else if (Platform.isMacOS) {
      final arm = _run('sysctl', ['-n', 'hw.optional.arm64']) == '1';
      final brand = _run('sysctl', ['-n', 'machdep.cpu.brand_string']);
      final mem = int.tryParse(_run('sysctl', ['-n', 'hw.memsize']));
      h = Hardware(
        os: 'macos',
        arch: arm ? 'arm64' : 'x86_64',
        appleSilicon: arm,
        description: '${brand.isEmpty ? 'Mac' : brand}${mem != null ? ' · ${(mem / (1 << 30)).round()} GB' : ''}',
        extra: {'memory_bytes': mem},
      );
    } else if (Platform.isLinux) {
      final arch = _run('uname', ['-m']);
      final gpu = File('/proc/driver/nvidia/version').existsSync()
          ? 'NVIDIA GPU'
          : (Directory('/dev/dri').existsSync() ? 'GPU (Vulkan possible)' : 'CPU only');
      h = Hardware(os: 'linux', arch: arch, description: 'Linux $arch · $gpu', extra: {'gpu': gpu});
    } else {
      h = const Hardware(os: 'other', arch: '', description: 'Unsupported platform');
    }
    return _cached = h;
  }

  static String _run(String exe, List<String> args) {
    try {
      return Process.runSync(exe, args).stdout.toString().trim();
    } catch (_) {
      return '';
    }
  }
}
