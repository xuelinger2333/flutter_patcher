import 'package:flutter/services.dart';
import 'package:flutter_patcher/flutter_patcher.dart';
import 'package:flutter_test/flutter_test.dart';

/// An app not built with `flutter_patcher build` cannot take patches.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    FlutterPatcher.debugAssumeSupported = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('flutter_patcher'),
          (call) async => null,
        );
  });

  test('checkUpdate, patchTarget and inspectPatch throw', () async {
    await expectLater(
      FlutterPatcher.inspectPatch(List.filled(146, 0)),
      throwsA(isA<PatcherException>()),
    );
    await expectLater(
      FlutterPatcher.checkUpdate(url: 'https://cdn.example.com'),
      throwsA(isA<PatcherException>()),
    );
    await expectLater(
      FlutterPatcher.patchTarget,
      throwsA(isA<PatcherException>()),
    );
  });
}
