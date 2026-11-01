import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

/// The channel added by the flutter_patcher engine patch. The engine puts
/// these assets in front of the application bundle, so rootBundle, images,
/// shaders and fonts all read the patched bytes.
const patcherAssetChannel = 'flutter_patcher/assets';

/// u32 count, then per asset: u32 key size, key, u32 byte size, bytes; all
/// little-endian, keys sorted.
Uint8List encodePatcherAssets(Map<String, Uint8List> assets) {
  final out = BytesBuilder(copy: false);
  void u32(int value) => out.add(
    (ByteData(4)..setUint32(0, value, Endian.little)).buffer.asUint8List(),
  );
  final keys = assets.keys.toList()..sort();
  u32(keys.length);
  for (final key in keys) {
    final name = utf8.encode(key), bytes = assets[key]!;
    u32(name.length);
    out.add(name);
    u32(bytes.length);
    out.add(bytes);
  }
  return out.takeBytes();
}

/// Called by the boot runner after archive authentication and before the
/// patched main. An engine without the channel replies empty.
Future<void> patcherInstallAssets(Map<String, Uint8List> assets) async {
  final reply = Completer<ByteData?>();
  ui.PlatformDispatcher.instance.sendPlatformMessage(
    patcherAssetChannel,
    ByteData.sublistView(encodePatcherAssets(assets)),
    reply.complete,
  );
  final data = await reply.future;
  if (data == null || data.lengthInBytes != 1 || data.getUint8(0) != 1) {
    throw StateError('The engine did not install the patch assets');
  }
}
