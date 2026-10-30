import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:flutter_patcher_cli/src/publish/protocol.dart';

void main() {
  final vectors =
      jsonDecode(File('../test/protocol/manifest-v1.json').readAsStringSync())
          as List;
  test('iOS releases are bytecode only', () {
    Map<String, String> fields(String abi, String strategy) => {
          'schema': '1',
          'key_id': 'release',
          'application_id': 'com.example.app',
          'channel': 'stable',
          'flavor': 'default',
          'version_code': '1',
          'abi': abi,
          'fingerprint': 'a' * 64,
          'strategy': strategy,
          'revision': '1',
          'minPluginVersion': '0.1.4',
          'action': 'withdraw',
          'withdraw_through_seq': '1'
        };
    expect(PublishManifest(fields('ios-arm64', 'bytecode')).fields['abi'],
        'ios-arm64');
    expect(() => PublishManifest(fields('ios-arm64', 'so')),
        throwsFormatException);
    expect(() => PublishManifest(fields('x86_64', 'bytecode')),
        throwsFormatException);
  });
  for (final row in vectors.cast<Map<String, dynamic>>()) {
    test(row['name'] as String, () {
      final bytes = base64.decode(row['payload'] as String);
      if (row['parse_valid'] != true) {
        expect(() => PublishManifest.parse(bytes), throwsFormatException);
      } else {
        final manifest = PublishManifest.parse(bytes);
        expect(
            manifest.signingBytes
                .map((b) => b.toRadixString(16).padLeft(2, '0'))
                .join(),
            row['signing_hex']);
        final signature = row['signature'] as String;
        final sig = [
          for (var i = 0; i < signature.length; i += 2)
            int.parse(signature.substring(i, i + 2), radix: 16)
        ];
        if (row['envelope_valid'] == true) {
          expect(manifest.envelope(sig), row['wire']);
        }
      }
    });
  }
}
