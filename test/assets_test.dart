import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_patcher/src/bootstrap/assets.dart';
import 'package:flutter_patcher/src/bootstrap/fonts.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('authentic subset font loads before application main', () async {
    final bytes = await File(Platform.environment['FLUTTER_PATCHER_TEST_FONT']!)
        .readAsBytes();
    await patcherLoadFonts({
      'OverlaySubset': [bytes],
    });
    await expectLater(patcherLoadFonts({'empty': []}), throwsArgumentError);
  }, skip: Platform.environment['FLUTTER_PATCHER_TEST_FONT'] == null);
  test('engine asset payload is sorted, length-prefixed and little-endian', () {
    final encoded = encodePatcherAssets({
      'b': Uint8List.fromList([9]),
      'a': Uint8List(0),
    });
    expect(encoded, [
      2,
      0,
      0,
      0,
      1,
      0,
      0,
      0,
      97,
      0,
      0,
      0,
      0,
      1,
      0,
      0,
      0,
      98,
      1,
      0,
      0,
      0,
      9,
    ]);
  });
  test('an engine without the asset channel fails the install', () async {
    // The test binding, like a stock engine, answers the unknown channel empty.
    await expectLater(
      patcherInstallAssets({
        'a': Uint8List.fromList([1]),
      }),
      throwsStateError,
    );
  });
}
