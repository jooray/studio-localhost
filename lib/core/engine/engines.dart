import '../models/registry.dart';
import 'engine.dart';
import 'hardware.dart';

/// Every engine adapter the app ships. The YuE2 family runs on mlx-Yue (MLX) and yue2.cpp (ggml).
const engineCatalog = <EngineDescriptor>[
  EngineDescriptor(
    id: 'sidecar-mlx',
    label: 'MLX (Apple Silicon)',
    runtime: 'mlx',
    families: ['yue2'],
    hosts: ['macos-arm64'],
    precisions: ['8bit', 'bf16'],
    speedHint: 'Measured on an M2 Max: a 25 s song in about 23 s at 8 steps (8-bit), extend +15 s in about 14 s.',
    background: 'Runs in a local Python process (uv venv). Keep the app open while it works.',
  ),
  EngineDescriptor(
    id: 'sidecar-yue2cpp',
    label: 'yue2.cpp (ggml: CUDA, Vulkan, Metal or CPU)',
    runtime: 'yue2cpp',
    families: ['yue2'],
    hosts: ['linux', 'macos'],
    speedHint: 'Fast with a CUDA or Vulkan GPU; CPU only takes many minutes per song.',
    background: 'Builds yue2.cpp locally; keep the app open while it works.',
  ),
  EngineDescriptor(
    id: 'android-native',
    label: 'yue2.cpp on this device (CPU)',
    runtime: 'android',
    families: ['yue2'],
    hosts: ['android'],
    speedHint: 'Phone CPU: several minutes per 10 s of audio at 8 steps.',
    background: 'Runs in the background with a notification and resumes after interruptions.',
  ),
];

EngineDescriptor? engineById(String? id) {
  for (final e in engineCatalog) {
    if (e.id == id) return e;
  }
  return null;
}

/// Engines that run on this hardware, best first.
List<EngineDescriptor> enginesFor(Hardware hw) {
  final keys = hw.hostKeys;
  return engineCatalog.where((e) => e.hosts.any(keys.contains)).toList();
}

/// Hardware decides: Apple Silicon -> MLX, other desktops -> yue2.cpp, Android -> on-device
/// yue2.cpp. A valid override from settings wins. With a model, only engines that can run it count.
EngineDescriptor? selectEngine(Hardware hw, {String override = '', ModelSpec? model}) {
  final candidates = enginesFor(hw).where((e) => model == null || e.runs(model)).toList();
  if (candidates.isEmpty) return null;
  for (final e in candidates) {
    if (e.id == override) return e;
  }
  return candidates.first;
}
