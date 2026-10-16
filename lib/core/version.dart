const String appName = 'YuE2 Studio';
const String appVersion = '0.1.0';
const int appBuild = 1;

/// Pinned upstream revisions used by "Set up engine".
const String mlxYueRepo = 'https://github.com/vanch007/mlx-Yue.git';
const String mlxYueCommit = 'c5b5a8190f78c74aa671a4caa19dae8b8e04b3d8';
const String yue2cppRepo = 'https://github.com/ServeurpersoCom/yue2.cpp.git';
const String yue2cppCommit = 'ecf74c145505acc5a726331a3e70a802656b7c31';
const String mlxWeightsRepo = 'vanch007/mlx-Yue2-3B';
const String ggufRepo = 'Serveurperso/YuE2-GGUF';

/// Compare dotted versions ("0.10.1" > "0.9"). Returns <0, 0, >0.
int compareVersions(String a, String b) {
  List<int> parse(String v) => v
      .trim()
      .replaceFirst(RegExp(r'^[vV]'), '')
      .split(RegExp(r'[.+-]'))
      .map((p) => int.tryParse(p) ?? 0)
      .toList();
  final x = parse(a), y = parse(b);
  for (var i = 0; i < 3; i++) {
    final d = (i < x.length ? x[i] : 0) - (i < y.length ? y[i] : 0);
    if (d != 0) return d;
  }
  return 0;
}
