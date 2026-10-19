/// App identity. The version matches pubspec.yaml (one version for every platform).
const String appName = 'Localhost Recording Studio';
const String appVersion = '0.4.8';
const int appBuild = 8;
const String appLicence = 'MIT';
const String appSourceUrl = 'https://github.com/jooray/studio-localhost';

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
