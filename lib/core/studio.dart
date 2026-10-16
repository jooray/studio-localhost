import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'engine/android_native_engine.dart';
import 'engine/engine.dart';
import 'engine/engines.dart';
import 'engine/hardware.dart';
import 'engine/sidecar_engine.dart';
import 'library/library.dart';
import 'library/song.dart';
import 'models/registry.dart';
import 'paths.dart';
import 'settings.dart';

/// The app's composition root: hardware, the model registry, the selected model + variant and
/// the engine that runs it. Widgets read it; nothing here builds UI.
class Studio extends ChangeNotifier {
  Studio({required this.settings, required this.registry, required this.hardware, required this.library});

  final Settings settings;
  final ModelRegistry registry;
  final Hardware hardware;
  final Library library;

  Engine? engine;

  List<EngineDescriptor> get availableEngines => enginesFor(hardware);

  /// The engine chosen by hardware (or the settings override).
  EngineDescriptor? get engineDescriptor => selectEngine(hardware, override: settings.engineOverride, model: model);

  /// The automatic choice, ignoring the override.
  EngineDescriptor? get recommendedEngine => selectEngine(hardware, model: model);

  ModelSpec? get model {
    final m = registry.byId(settings.activeModel);
    if (m != null) return m;
    final engines = enginesFor(hardware);
    for (final mm in registry.models) {
      if (engines.any((e) => e.runs(mm))) return mm;
    }
    return null;
  }

  ModelFormat? get format {
    final e = engineDescriptor;
    return e == null ? null : model?.formatFor(e.id);
  }

  ModelVariant? get variant {
    final m = model, f = format, e = engineDescriptor;
    if (m == null || f == null || e == null) return null;
    return f.variant(settings.variantFor(m.id, f.id)) ?? f.defaultVariant(e.id);
  }

  bool get licenceAccepted {
    final m = model;
    return m != null && settings.licenceAccepted(m.id, m.licence.spdx);
  }

  /// First run (or the model/licence changed): show the setup flow.
  bool get needsSetup => !settings.setupComplete || !licenceAccepted || engine == null;

  /// Where a model file of the current format lives on this device.
  String modelFilePath(ModelFile f) => p.join(AppPaths.instance.modelDir(model!.id, format!.id), f.name);

  JobContext context({String? sourceDir}) =>
      JobContext(model: model!, format: format!, variant: variant!, sourceDir: sourceDir);

  /// The context for an existing song: its own model and variant when still known.
  JobContext contextFor(Song song) {
    final m = registry.byId(song.modelId) ?? model!;
    final e = engineDescriptor!;
    final f = m.formatFor(e.id) ?? format!;
    final v = f.variant(song.model['variant'] as String?) ?? variant!;
    final src = song.sourceDir ?? (song.parentId != null ? library.byId(song.parentId)?.dir : null);
    return JobContext(model: m, format: f, variant: v, sourceDir: src);
  }

  /// (Re)create the engine for the current choice. Call after engine/model settings change.
  Future<void> rebuildEngine() async {
    final d = engineDescriptor;
    final old = engine;
    if (old != null && old.descriptor.id == d?.id) {
      notifyListeners();
      return;
    }
    engine = null;
    if (old != null) {
      await old.shutdown();
      old.dispose();
    }
    if (d != null) {
      engine = Platform.isAndroid ? AndroidNativeEngine(d) : SidecarEngine(d, settings, defaultContext: () => context());
      engine!.addListener(notifyListeners);
    }
    notifyListeners();
  }

  void selectModel(String id) {
    settings.activeModel = id;
    rebuildEngine();
  }

  void selectVariant(String id) {
    final m = model, f = format;
    if (m == null || f == null) return;
    settings.setVariant(m.id, f.id, id);
    notifyListeners();
  }

  Future<void> selectEngineOverride(String id) async {
    settings.engineOverride = id;
    await rebuildEngine();
  }
}
