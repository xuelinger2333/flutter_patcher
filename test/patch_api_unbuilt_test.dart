import 'package:flutter/services.dart';
import 'package:flutter_patcher/flutter_patcher.dart';
import 'package:flutter_test/flutter_test.dart';

/// An app not built with `flutter_patcher build`, such as one started with
/// `flutter run`, takes no patches and says so without failing the app.
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

  test('isAvailable is false and checkUpdate finds no update', () async {
    expect(await FlutterPatcher.isAvailable, isFalse);
    final result = await FlutterPatcher.checkUpdate(
      url: 'https://cdn.example.com',
    );
    expect(result.hasUpdate, isFalse);
  });

  test('patchTarget and inspectPatch throw', () async {
    await expectLater(
      FlutterPatcher.inspectPatch(List.filled(146, 0)),
      throwsA(isA<PatcherException>()),
    );
    await expectLater(
      FlutterPatcher.patchTarget,
      throwsA(isA<PatcherException>()),
    );
  });
}
