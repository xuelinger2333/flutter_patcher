import 'dart:convert';
import 'dart:typed_data';
import 'protocol.dart';

/// Complete publication key set, authorized only by the host's trust root.
class TrustUpdate {
  static const domain = 'flutter_patcher.trust.v1\n';
  static const scopeKeys = {
    'application_id',
    'channel',
    'flavor',
    'version_code',
    'abi',
    'fingerprint',
    'strategy'
  };
  final Map<String, String> fields;
  TrustUpdate(Map<String, String> values) : fields = Map.unmodifiable(values) {
    final expected = {...scopeKeys, 'schema', 'revision', 'keys'};
    if (fields.length != expected.length ||
        !fields.keys.every(expected.contains) ||
        fields['schema'] != '1') {
      throw const FormatException('Trust fields/schema');
    }
    // Reuse the exact manifest scope and revision grammar.
    PublishManifest({
      for (final key in scopeKeys) key: fields[key]!,
      'schema': '1',
      'key_id': 'root',
      'revision': fields['revision']!,
      'minPluginVersion': '0.0.0',
      'action': 'withdraw',
      'withdraw_through_seq': '1',
    });
    parseKeys(fields['keys']!);
  }

  static Map<String, String> parseKeys(String text) {
    if (text == '-') return {};
    final rows = text.split(',');
    final sorted = [...rows]..sort();
    if (rows.length > 32 || rows.join(',') != sorted.join(',')) {
      throw const FormatException('Key set order/size');
    }
    final keys = <String, String>{};
    for (final row in rows) {
      final pair = row.split(':');
      if (pair.length != 2 ||
          !RegExp(r'^[A-Za-z0-9_-]{1,64}$').hasMatch(pair[0]) ||
          keys.containsKey(pair[0])) {
        throw const FormatException('Key identifier');
      }
      final raw = base64Decode(pair[1]);
      if (raw.length != 32 || base64Encode(raw) != pair[1]) {
        throw const FormatException('Key encoding');
      }
      keys[pair[0]] = pair[1];
    }
    return keys;
  }

  String get canonical => jsonEncode(
      {for (final key in fields.keys.toList()..sort()) key: fields[key]});
  Uint8List get signingBytes =>
      Uint8List.fromList(utf8.encode('$domain$canonical'));
  String envelope(List<int> signature) {
    if (signature.length != 64) throw const FormatException('Signature size');
    return jsonEncode({
      'payload': base64Encode(utf8.encode(canonical)),
      'signature': base64Encode(signature)
    });
  }
}
