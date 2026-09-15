import 'dart:convert';
import 'package:crypto/crypto.dart';
import '../publish/protocol.dart';
import '../publish/trust.dart';

/// Public build inputs only. Native receives this policy inside the APK itself.
class HostPolicy {
  final Map<String, String> fields;
  HostPolicy(Map<String, String> values) : fields = Map.unmodifiable(values) {
    final expected = {
      ...TrustUpdate.scopeKeys.where((key) => key != 'fingerprint'),
      'schema',
      'fptc_key',
      'root_key',
      'keys'
    };
    if (fields.length != expected.length ||
        !fields.keys.every(expected.contains) ||
        fields['schema'] != '1' ||
        fields['strategy'] != 'bytecode') {
      throw const FormatException('Host policy fields/schema/strategy');
    }
    PublishManifest({
      for (final key in TrustUpdate.scopeKeys)
        key: key == 'fingerprint' ? '0' * 64 : fields[key]!,
      'schema': '1',
      'key_id': 'root',
      'revision': '1',
      'minPluginVersion': '0.0.0',
      'action': 'withdraw',
      'withdraw_through_seq': '1'
    });
    for (final name in ['fptc_key', 'root_key']) {
      final key = base64Decode(fields[name]!);
      if (key.length != 32 || base64Encode(key) != fields[name]) {
        throw const FormatException('Host public key encoding');
      }
    }
    TrustUpdate.parseKeys(fields['keys']!);
  }
  factory HostPolicy.parse(String text) {
    if (text.length > 16384) {
      throw const FormatException('Host policy too large');
    }
    final policy = HostPolicy((jsonDecode(text) as Map).cast<String, String>());
    if (text != policy.canonical) {
      throw const FormatException('Noncanonical host policy');
    }
    return policy;
  }
  String get canonical => jsonEncode(
      {for (final key in fields.keys.toList()..sort()) key: fields[key]});
  String get digest => sha256.convert(utf8.encode(canonical)).toString();
}
