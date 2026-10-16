import 'dart:typed_data';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_patcher/src/bootstrap/overlay.dart';
import 'package:flutter_patcher/src/bootstrap/fonts.dart';

class _Host extends CachingAssetBundle {
  final reads = <String>[];
  @override
  Future<ByteData> load(String key) async {
    reads.add(key);
    return ByteData.sublistView(Uint8List.fromList([104, 111, 115, 116]));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('authentic subset font loads before application main', () async {
    final bytes =
        await File(Platform.environment['FLUTTER_PATCHER_TEST_FONT']!).readAsBytes();
    await patcherLoadFonts({
      'OverlaySubset': [bytes]
    });
    await expectLater(patcherLoadFonts({'empty': []}), throwsArgumentError);
  }, skip: Platform.environment['FLUTTER_PATCHER_TEST_FONT'] == null);
  test('overlay handles text, buffers and fallback without mutating input',
      () async {
    final host = _Host(), bytes = Uint8List.fromList([110, 101, 119]);
    final overlay = PatcherOverlayBundle(host, {'image': bytes});
    expect(await overlay.loadString('image'), 'new');
    expect(await overlay.loadString('missing'), 'host');
    expect(host.reads, ['missing']);
    final loaded = await overlay.load('image');
    loaded.setUint8(0, 0);
    expect(bytes.first, 110);
    final buffer = await overlay.loadBuffer('image');
    expect(buffer.length, 3);
    buffer.dispose();
  });
  test('whole bundle created before install sees new bytes and clears caches',
      () async {
    patcherInstallAssets({});
    final host = _Host(), whole = patcherWholeBundle(host);
    expect(await whole.loadString('key'), 'host');
    final input = Uint8List.fromList([97]);
    patcherInstallAssets({'key': input});
    input[0] = 98;
    expect(await whole.loadString('key'), 'a');
    patcherInstallAssets({
      'key': Uint8List.fromList([99])
    });
    expect(await whole.loadString('key'), 'c');
    patcherInstallAssets({});
    expect(await whole.loadString('key'), 'host');
  });
}
