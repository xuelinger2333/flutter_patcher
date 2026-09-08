import 'dart:typed_data';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_patcher/src/patch_bootstrap.dart';

class ApplicationBinding extends WidgetsFlutterBinding {}

void main() {
  test('bare platform message preserves application binding ownership',
      () async {
    expect(() => WidgetsBinding.instance, throwsAssertionError);
    var original = 0;
    await PatchBootstrap.run(
        original: () {
          original++;
          ApplicationBinding();
        },
        fingerprint: 'ab' * 32,
        publicKeyBase64: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
        loadModule: (Uint8List _) async => throw StateError('Must not load'));
    expect(original, 1);
    expect(WidgetsBinding.instance, isA<ApplicationBinding>());
  });
}
