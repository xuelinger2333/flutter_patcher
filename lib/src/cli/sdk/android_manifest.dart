import 'dart:convert';

import '../core.dart';

/// The root attributes of an app bundle's `manifest/AndroidManifest.xml`,
/// which aapt2 writes as an `XmlNode` protocol buffer (`Resources.proto`)
/// and `aapt dump badging` cannot read. Keys are attribute names without
/// their namespace (`package`, `versionCode`).
Map<String, String> manifestAttributes(List<int> bytes) {
  const code = 'BUILD_APK_INVALID';
  final root = _fields(bytes, code)[1];
  require(
    root != null && root.length == 1 && root.single is List<int>,
    code,
    'The app bundle manifest has no root element.',
  );
  final element = _fields(root!.single as List<int>, code);
  require(
    _text(element[3]) == 'manifest',
    code,
    'The app bundle manifest root is not <manifest>.',
  );
  final attributes = <String, String>{};
  for (final attribute in element[4] ?? const <Object>[]) {
    final fields = _fields(attribute as List<int>, code);
    attributes[_text(fields[2])] = _text(fields[3]);
  }
  return attributes;
}

String _text(List<Object>? values) =>
    values == null ? '' : utf8.decode(values.last as List<int>);

/// The fields of one message: field number → its values in order. Only
/// length-delimited values are kept (as bytes); the others are skipped.
Map<int, List<Object>> _fields(List<int> bytes, String code) {
  final result = <int, List<Object>>{};
  var at = 0;
  int varint() {
    var value = 0, shift = 0;
    while (true) {
      require(at < bytes.length && shift < 64, code, 'Truncated manifest.');
      final byte = bytes[at++];
      value |= (byte & 0x7f) << shift;
      if (byte < 0x80) return value;
      shift += 7;
    }
  }

  while (at < bytes.length) {
    final tag = varint();
    switch (tag & 7) {
      case 0:
        varint();
      case 1:
        at += 8;
      case 2:
        final length = varint();
        require(
          length >= 0 && at + length <= bytes.length,
          code,
          'Truncated manifest.',
        );
        (result[tag >> 3] ??= []).add(bytes.sublist(at, at + length));
        at += length;
      case 5:
        at += 4;
      default:
        throw Failure(code, 'Unreadable manifest.');
    }
    require(at <= bytes.length, code, 'Truncated manifest.');
  }
  return result;
}
