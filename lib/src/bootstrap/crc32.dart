import 'dart:typed_data';

// IEEE CRC-32, reflected polynomial; identical to ZIP's CRC field.
final _table = Uint32List.fromList(List<int>.generate(256, (value) {
  var crc = value;
  for (var bit = 0; bit < 8; bit++) {
    crc = (crc >> 1) ^ ((crc & 1) != 0 ? 0xedb88320 : 0);
  }
  return crc;
}));

int patchCrc32(Uint8List bytes) {
  var crc = 0xffffffff;
  for (final byte in bytes) {
    crc = (crc >> 8) ^ _table[(crc ^ byte) & 0xff];
  }
  return crc ^ 0xffffffff;
}
