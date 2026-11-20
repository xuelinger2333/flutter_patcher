import 'dart:io';

import 'package:test/test.dart';
import 'package:flutter_patcher/src/cli/core.dart';
import 'package:flutter_patcher/src/cli/sdk/android_manifest.dart';

/// An app bundle's manifest, which `aapt dump badging` cannot read: the
/// sample is the example app's, from `flutter build appbundle` (3.47.9).
void main() {
  final sample = File('test/cli/samples/aab-manifest.pb').readAsBytesSync();
  Matcher invalid() => throwsA(
    isA<Failure>().having((e) => e.code, 'code', 'BUILD_APK_INVALID'),
  );

  test('the root attributes name the app and its versionCode', () {
    final attributes = manifestAttributes(sample);
    expect(
      attributes['package'],
      'com.flutter_patcher.flutter_patcher_example',
    );
    expect(attributes['versionCode'], '1');
  });

  test('a truncated or foreign file is refused', () {
    expect(() => manifestAttributes(sample.sublist(0, 40)), invalid());
    expect(() => manifestAttributes(const []), invalid());
    // A length-delimited root whose element is not <manifest>.
    expect(
      () => manifestAttributes([0x0a, 0x05, 0x1a, 0x03, 0x61, 0x70, 0x70]),
      invalid(),
    );
  });
}
