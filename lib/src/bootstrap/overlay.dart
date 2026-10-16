import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

// Keep the injected constructor/call references visible to CFE validation
// before the Kernel transform. The transform uses these exact targets.
Widget patcherWrap(Widget child) =>
    DefaultAssetBundle(bundle: patcherOverlayBundle(), child: child);

/// Module-local state. The boot runner supplies only authenticated archive
/// bytes here.
final Map<String, Uint8List> _assets = {};
AssetBundle? _bundle;
AssetBundle? _whole;

void patcherInstallAssets(Map<String, Uint8List> assets) {
  final copied = {
    for (final entry in assets.entries)
      entry.key: Uint8List.fromList(entry.value),
  };
  _assets
    ..clear()
    ..addAll(copied);
  _whole?.clear();
  _bundle = null; // Discard decoded string/structured-data caches on reinstall.
}

AssetBundle patcherOverlayBundle() =>
    _bundle ??= PatcherOverlayBundle(rootBundle, _assets);

/// The compiler wraps the original rootBundle initializer in whole mode.
AssetBundle patcherWholeBundle(AssetBundle original) =>
    _whole = PatcherOverlayBundle(original, _assets);

class PatcherOverlayBundle extends CachingAssetBundle {
  PatcherOverlayBundle(this.fallback, this.assets);
  final AssetBundle fallback;
  final Map<String, Uint8List> assets;

  @override
  Future<ByteData> load(String key) async {
    final value = assets[key];
    if (value == null) return fallback.load(key);
    return ByteData.sublistView(Uint8List.fromList(value));
  }

  @override
  Future<ui.ImmutableBuffer> loadBuffer(String key) async {
    final value = assets[key];
    if (value == null) return fallback.loadBuffer(key);
    return ui.ImmutableBuffer.fromUint8List(Uint8List.fromList(value));
  }

  @override
  void evict(String key) {
    super.evict(key);
    fallback.evict(key);
  }

  @override
  void clear() {
    super.clear();
    fallback.clear();
  }
}
