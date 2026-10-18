import 'dart:io';

import 'package:path/path.dart' as p;

import '../models/registry.dart';
import '../paths.dart';
import '../settings.dart';

/// Desktop runtime adapters: where a runtime lives, which Python runs the sidecar for it and
/// the `configure` message for the sidecar backend. Paths come from settings or auto-detection.
abstract class SidecarRuntime {
  const SidecarRuntime(this.settings);

  final Settings settings;

  /// Sidecar backend name (studio_engine backends table).
  String get backend;

  String python();
  String cwd();
  Map<String, dynamic> config(ModelSpec model, ModelFormat format, ModelVariant variant);

  /// Files the runtime needs for [variant]: {label: path}. Missing ones mean setup is needed.
  Map<String, String> requiredFiles(ModelSpec model, ModelFormat format, ModelVariant variant);

  /// Is the runtime itself (code, venv, binaries) installed?
  bool get installed;

  String get installDir;

  static SidecarRuntime of(String runtime, Settings s) => switch (runtime) {
        'mlx' => MlxRuntime(s),
        _ => Yue2CppRuntime(s),
      };

  String ownSidecarPython() => AppPaths.venvPython(AppPaths.instance.sidecarVenv);
}

/// mlx-Yue (vanch007/mlx-Yue) in its own uv venv; the sidecar runs inside that venv.
class MlxRuntime extends SidecarRuntime {
  const MlxRuntime(super.settings);

  @override
  String get backend => 'mlx';

  /// Settings > env STUDIO_MLX_ENGINE_DIR > the app's own checkout.
  String get engineDir {
    final v = settings.runtime('mlx.dir');
    if (v.isNotEmpty) return v;
    final env = Platform.environment['STUDIO_MLX_ENGINE_DIR'];
    if (env != null && env.isNotEmpty) return env;
    return AppPaths.instance.runtimeDir('mlx-Yue');
  }

  @override
  String get installDir => engineDir;

  @override
  bool get installed => File(python()).existsSync();

  @override
  String python() {
    final o = settings.sidecarPythonOverride;
    return o.isNotEmpty ? o : AppPaths.venvPython(p.join(engineDir, '.venv'));
  }

  @override
  String cwd() => engineDir;

  /// The app's own folder for this format. It holds `<repo name>/` (exactly the converted file
  /// set mlx-Yue's verify_conversion accepts), `vae/` beside it and `.verified.json`.
  String modelRoot(ModelSpec model, ModelFormat format) => AppPaths.instance.modelDir(model.id, format.id);

  static String modelName(ModelFormat format) => format.repo.split('/').last;

  String verifiedMarker(ModelSpec model, ModelFormat format) => p.join(modelRoot(model, format), '.verified.json');

  /// The converted model folder: settings, the app's model root, or an existing download inside
  /// the engine checkout (`models/<repo name>`).
  String modelDir(ModelSpec model, ModelFormat format) {
    final v = settings.runtime('mlx.modelDir');
    if (v.isNotEmpty) return v;
    final root = modelRoot(model, format);
    final own = p.join(root, modelName(format));
    if (Directory(root).existsSync()) return own;
    final inEngine = p.join(engineDir, 'models', modelName(format));
    if (Directory(inEngine).existsSync()) return inEngine;
    return own;
  }

  /// Is the model folder the app's own (so setup may lay it out, repair and download into it)?
  bool ownsModelDir(ModelSpec model, ModelFormat format) =>
      p.equals(modelDir(model, format), p.join(modelRoot(model, format), modelName(format)));

  /// The VAE folder sits next to the model folder, never inside it.
  String vaeDir(ModelSpec model, ModelFormat format) {
    final v = settings.runtime('mlx.vaeDir');
    if (v.isNotEmpty) return v;
    return p.join(p.dirname(modelDir(model, format)), 'vae');
  }

  @override
  Map<String, dynamic> config(ModelSpec model, ModelFormat format, ModelVariant variant) => {
        'backend': backend,
        'family': model.family,
        'engine_dir': engineDir,
        'model_dir': modelDir(model, format),
        'vae_dir': vaeDir(model, format),
      };

  @override
  Map<String, String> requiredFiles(ModelSpec model, ModelFormat format, ModelVariant variant) {
    final dir = modelDir(model, format);
    final files = <String, String>{};
    for (final pattern in variant.patterns) {
      if (pattern.endsWith('.safetensors')) files[pattern] = p.join(dir, pattern);
    }
    files['conversion.json'] = p.join(dir, 'conversion.json');
    files['vae'] = p.join(vaeDir(model, format), 'model.safetensors');
    // The app's own folder must also have passed mlx-Yue's verify_conversion once.
    if (ownsModelDir(model, format)) files['verification'] = verifiedMarker(model, format);
    return files;
  }
}

/// yue2.cpp built locally (yue-synth), weights as GGUF files.
class Yue2CppRuntime extends SidecarRuntime {
  const Yue2CppRuntime(super.settings);

  @override
  String get backend => 'yue2cpp';

  String get checkoutDir => AppPaths.instance.runtimeDir('yue2.cpp');

  String get binDir {
    final v = settings.runtime('yue2cpp.binDir');
    return v.isNotEmpty ? v : p.join(checkoutDir, 'build');
  }

  @override
  String get installDir => checkoutDir;

  @override
  bool get installed =>
      File(p.join(binDir, 'yue-synth')).existsSync() && File(python()).existsSync();

  @override
  String python() {
    final o = settings.sidecarPythonOverride;
    if (o.isNotEmpty) return o;
    return ownSidecarPython();
  }

  @override
  String cwd() => AppPaths.instance.dataDir;

  String ggufDir(ModelSpec model, ModelFormat format) {
    final v = settings.runtime('gguf.dir');
    return v.isNotEmpty ? v : AppPaths.instance.modelDir(model.id, format.id);
  }

  @override
  Map<String, dynamic> config(ModelSpec model, ModelFormat format, ModelVariant variant) {
    final dir = ggufDir(model, format);
    final device = settings.runtime('yue2cpp.device');
    return {
      'backend': backend,
      'family': model.family,
      'yue2cpp_bin_dir': binDir,
      'gguf_model': p.join(dir, variant.file('backbone')?.name ?? ''),
      'gguf_vae': p.join(dir, variant.file('vae')?.name ?? ''),
      if (device.isNotEmpty) 'device': device,
    };
  }

  @override
  Map<String, String> requiredFiles(ModelSpec model, ModelFormat format, ModelVariant variant) {
    final dir = ggufDir(model, format);
    return {for (final f in variant.files) f.name: p.join(dir, f.name)};
  }
}
