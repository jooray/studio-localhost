import 'dart:convert';

import 'package:flutter/services.dart';

/// The model registry (assets/models/registry.json): every music model the app knows, its licence,
/// what it can do and which engine formats it ships in. Generic code only reads these fields.
class ModelRegistry {
  ModelRegistry(this.models);

  final List<ModelSpec> models;

  static Future<ModelRegistry> load([AssetBundle? bundle]) async {
    final text = await (bundle ?? rootBundle).loadString('assets/models/registry.json');
    return ModelRegistry.fromJson(jsonDecode(text) as Map<String, dynamic>);
  }

  factory ModelRegistry.fromJson(Map<String, dynamic> j) =>
      ModelRegistry([for (final m in (j['models'] as List)) ModelSpec.fromJson(Map<String, dynamic>.from(m as Map))]);

  ModelSpec? byId(String? id) {
    for (final m in models) {
      if (m.id == id) return m;
    }
    return null;
  }

  /// Models with at least one format the engine can run.
  List<ModelSpec> forEngine(String engineId) => models.where((m) => m.formatFor(engineId) != null).toList();
}

class Licence {
  const Licence({required this.spdx, required this.name, required this.url, required this.summary});

  final String spdx;
  final String name;
  final String url;
  final String summary;

  factory Licence.fromJson(Map<String, dynamic> j) => Licence(
        spdx: j['spdx'] as String,
        name: j['name'] as String? ?? j['spdx'] as String,
        url: j['url'] as String? ?? '',
        summary: j['summary'] as String? ?? '',
      );
}

class ModelFeatures {
  const ModelFeatures(this._j);

  final Map<String, dynamic> _j;

  bool get generate => _j['generate'] != false;
  bool get instrumental => _j['instrumental'] == true;
  bool get extend => _j['extend'] == true;
  bool get rerender => _j['rerender'] == true;
  bool get abcScore => _j['abc_score'] == true;
  bool get lyricsSections => _j['lyrics_sections'] == true;
  List<String> get planningModes => List<String>.from(_j['planning_modes'] as List? ?? const []);
}

class ModelLimits {
  const ModelLimits(this._j);

  final Map<String, dynamic> _j;

  double get maxSeconds => (_j['max_seconds'] as num? ?? 360).toDouble();
  int get maxTokens => (_j['max_tokens'] as num? ?? 9000).toInt();
  int get frameRate => (_j['frame_rate'] as num? ?? 25).toInt();
  int get sampleRate => (_j['sample_rate'] as num? ?? 48000).toInt();
  List<int> get steps => [for (final s in (_j['steps'] as List? ?? const [32])) (s as num).toInt()];
  int get defaultSteps => (_j['default_steps'] as num? ?? steps.last).toInt();
}

class ModelFile {
  const ModelFile({required this.role, required this.name, required this.bytes, required this.sha256, required this.url});

  final String role;
  final String name;
  final int bytes;
  final String sha256;
  final String url;

  factory ModelFile.fromJson(Map<String, dynamic> j) => ModelFile(
        role: j['role'] as String? ?? '',
        name: j['name'] as String,
        bytes: (j['bytes'] as num).toInt(),
        sha256: j['sha256'] as String? ?? '',
        url: j['url'] as String,
      );

  Map<String, dynamic> toJson() => {'role': role, 'name': name, 'bytes': bytes, 'sha256': sha256, 'url': url};
}

class ModelVariant {
  ModelVariant(this._j)
      : files = [for (final f in (_j['files'] as List? ?? const [])) ModelFile.fromJson(Map<String, dynamic>.from(f as Map))];

  final Map<String, dynamic> _j;
  final List<ModelFile> files;

  String get id => _j['id'] as String;
  String get name => _j['name'] as String? ?? id;
  String get note => _j['note'] as String? ?? '';
  List<String> get patterns => List<String>.from(_j['patterns'] as List? ?? const []);
  List<String> get recommendedFor => List<String>.from(_j['recommended_for'] as List? ?? const []);

  /// Download size. Shared files (same name) count once.
  int get bytes {
    if (_j['bytes'] is num) return (_j['bytes'] as num).toInt();
    final seen = <String>{};
    var sum = 0;
    for (final f in files) {
      if (seen.add(f.name)) sum += f.bytes;
    }
    return sum;
  }

  ModelFile? file(String role) {
    for (final f in files) {
      if (f.role == role) return f;
    }
    return null;
  }
}

class ModelFormat {
  ModelFormat(this._j)
      : variants = [for (final v in (_j['variants'] as List? ?? const [])) ModelVariant(Map<String, dynamic>.from(v as Map))];

  final Map<String, dynamic> _j;
  final List<ModelVariant> variants;

  String get id => _j['id'] as String;
  String get kind => _j['kind'] as String? ?? 'files';
  String get repo => _j['repo'] as String? ?? '';

  /// Pinned repo revision for hf-snapshot formats.
  String get revision => _j['revision'] as String? ?? 'main';
  List<String> get engines => List<String>.from(_j['engines'] as List? ?? const []);
  Map<String, dynamic> get runtime => Map<String, dynamic>.from(_j['runtime'] as Map? ?? const {});
  String? get licenceNote => _j['licence_note'] as String?;

  ModelVariant? variant(String? id) {
    for (final v in variants) {
      if (v.id == id) return v;
    }
    return null;
  }

  ModelVariant defaultVariant(String engineId) {
    for (final v in variants) {
      if (v.recommendedFor.contains(engineId)) return v;
    }
    return variants.first;
  }
}

class ModelSpec {
  ModelSpec._(this._j, this.licence, this.features, this.limits, this.formats);

  factory ModelSpec.fromJson(Map<String, dynamic> j) => ModelSpec._(
        j,
        Licence.fromJson(Map<String, dynamic>.from(j['licence'] as Map)),
        ModelFeatures(Map<String, dynamic>.from(j['features'] as Map? ?? const {})),
        ModelLimits(Map<String, dynamic>.from(j['limits'] as Map? ?? const {})),
        [for (final f in (j['formats'] as List? ?? const [])) ModelFormat(Map<String, dynamic>.from(f as Map))],
      );

  final Map<String, dynamic> _j;
  final Licence licence;
  final ModelFeatures features;
  final ModelLimits limits;
  final List<ModelFormat> formats;

  String get id => _j['id'] as String;
  String get name => _j['name'] as String? ?? id;
  String get family => _j['family'] as String;
  String get by => _j['by'] as String? ?? '';
  String get summary => _j['summary'] as String? ?? '';
  String get homepage => _j['homepage'] as String? ?? '';

  ModelFormat? formatFor(String engineId) {
    for (final f in formats) {
      if (f.engines.contains(engineId)) return f;
    }
    return null;
  }
}
