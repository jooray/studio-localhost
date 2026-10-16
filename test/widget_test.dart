import 'package:flutter_test/flutter_test.dart';
import 'package:yue2_studio/core/version.dart';

void main() {
  test('version comparison', () {
    expect(compareVersions('0.1.0', '0.1.0'), 0);
    expect(compareVersions('0.2.0', appVersion) > 0, isTrue);
    expect(compareVersions('v0.10.0', '0.9.9') > 0, isTrue);
    expect(compareVersions('0.0.9', appVersion) < 0, isTrue);
  });
}
