import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_patcher/src/bootstrap/crc32.dart';

void main() {
  test('ZIP CRC matches standard check value and independent zlib fixtures',
      () {
    expect(patchCrc32(Uint8List(0)), 0);
    expect(
        patchCrc32(Uint8List.fromList(ascii.encode('123456789'))), 0xcbf43926);
    // Python zlib.crc32(bytes((i*37+11)%256 for i in range(length))).
    for (final row in {
      1: 0x45d03605,
      255: 0x6626d95d,
      256: 0x8ed7a350,
      257: 0x2e35b052,
      2097152: 0xdf274c60
    }.entries) {
      final bytes = Uint8List.fromList(
          List.generate(row.key, (i) => (i * 37 + 11) % 256));
      expect(patchCrc32(bytes), row.value, reason: 'length=${row.key}');
      expect(
          patchCrc32(Uint8List.sublistView(
              Uint8List.fromList([99, ...bytes, 98]), 1, bytes.length + 1)),
          row.value);
    }
  });
}
