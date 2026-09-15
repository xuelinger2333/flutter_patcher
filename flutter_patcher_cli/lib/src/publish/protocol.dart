import 'dart:convert';
import 'dart:typed_data';

/// V1 accepts canonical ASCII JSON only. All numbers are decimal strings.
/// This is a signing codec, not proof that a publisher is trusted.
class PublishManifest {
  PublishManifest(Map<String, String> fields)
      : fields = Map.unmodifiable(fields) {
    _validate();
  }

  final Map<String, String> fields;
  static const domain = 'flutter_patcher.manifest.v1\n';
  static const common = {
    'schema',
    'key_id',
    'application_id',
    'channel',
    'flavor',
    'version_code',
    'abi',
    'fingerprint',
    'strategy',
    'revision',
    'minPluginVersion',
    'action'
  };

  factory PublishManifest.parse(List<int> bytes) {
    if (bytes.length > 16384) throw const FormatException('Manifest too large');
    final text = utf8.decode(bytes);
    final json = jsonDecode(text);
    if (json is! Map<String, dynamic> || json.values.any((v) => v is! String)) {
      throw const FormatException('String fields required');
    }
    final manifest = PublishManifest(json.cast<String, String>());
    if (text != manifest.canonical) {
      throw const FormatException('Noncanonical manifest');
    }
    return manifest;
  }

  String get canonical {
    final keys = fields.keys.toList()..sort();
    return jsonEncode({for (final key in keys) key: fields[key]});
  }

  Uint8List get signingBytes =>
      Uint8List.fromList(utf8.encode('$domain$canonical'));

  String envelope(List<int> signature) {
    if (signature.length != 64) throw const FormatException('Signature size');
    return jsonEncode({
      'payload': base64.encode(utf8.encode(canonical)),
      'signature': base64.encode(signature),
    });
  }

  void _validate() {
    void check(bool valid, String reason) {
      if (!valid) throw FormatException(reason);
    }

    bool matches(String key, String pattern) =>
        RegExp('^(?:$pattern)\$').hasMatch(fields[key] ?? '');
    void number(String key, int max) {
      check(matches(key, r'[1-9][0-9]{0,15}'), key);
      check(BigInt.parse(fields[key]!) <= BigInt.from(max), key);
    }

    final publish = fields['action'] == 'publish';
    final expected = {
      ...common,
      if (publish) ...{'patch_seq', 'sha256', 'size', 'url'} else
        'withdraw_through_seq'
    };
    check(
        fields.length == expected.length &&
            fields.keys.every(expected.contains),
        'Unexpected fields');
    check(fields['schema'] == '1', 'Schema');
    check(publish || fields['action'] == 'withdraw', 'Action');
    check(
        fields.values.every((v) =>
            v.length <= 2048 &&
            v.codeUnits
                .every((c) => c >= 0x21 && c <= 0x7e && c != 34 && c != 92)),
        'ASCII unescaped values required');
    for (final key in ['key_id', 'channel', 'flavor']) {
      check(matches(key, r'[A-Za-z0-9_-]{1,64}'), key);
    }
    check(
        matches('application_id',
            r'[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+'),
        'Application');
    check(fields['abi'] == 'arm64-v8a', 'ABI');
    check({'bytecode', 'so'}.contains(fields['strategy']), 'Strategy');
    check(
        matches('fingerprint', r'[0-9a-f]{64}') ||
            (fields['strategy'] == 'so' && fields['fingerprint'] == '-'),
        'Fingerprint');
    check(
        matches('minPluginVersion',
            r'(0|[1-9][0-9]{0,5})\.(0|[1-9][0-9]{0,5})\.(0|[1-9][0-9]{0,5})'),
        'Plugin version');
    number('version_code', 2100000000);
    number('revision', 9007199254740991);
    number(publish ? 'patch_seq' : 'withdraw_through_seq', 4294967295);
    if (publish) {
      number('size', 320 * 1024 * 1024);
      check(matches('sha256', r'[0-9a-f]{64}'), 'SHA256');
      check(
          matches('url',
              r"https://[a-z0-9]+(?:[.-][a-z0-9]+)*(?::[1-9][0-9]{0,4})?(?:/(?:[A-Za-z0-9._~!$&'()*+,;=:@/?-]|%[0-9A-F]{2})*)?"),
          'URL syntax');
      final uri = Uri.tryParse(fields['url']!);
      check(
          uri != null &&
              uri.scheme == 'https' &&
              uri.host.isNotEmpty &&
              uri.port <= 65535 &&
              uri.userInfo.isEmpty &&
              !uri.hasFragment,
          'HTTPS URL required');
    }
  }
}
