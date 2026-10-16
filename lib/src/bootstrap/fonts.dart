import 'dart:typed_data';
import 'package:flutter/services.dart';

/// Called by the boot runner after archive authentication and before the
/// patched main.
/// Load all faces of one family together; registering faces separately can
/// replace an earlier registration of that same family.
Future<void> patcherLoadFonts(Map<String, List<Uint8List>> families) async {
  for (final entry in families.entries) {
    if (entry.key.isEmpty || entry.value.isEmpty) {
      throw ArgumentError('Font family and faces must be nonempty');
    }
    final loader = FontLoader(entry.key);
    for (final bytes in entry.value) {
      if (bytes.isEmpty) throw ArgumentError('Empty font face');
      loader.addFont(Future.value(ByteData.sublistView(bytes)));
    }
    await loader.load();
  }
}
