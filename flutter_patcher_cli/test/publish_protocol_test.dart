import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:flutter_patcher_cli/src/publish/protocol.dart';

void main() {
  final vectors =
      jsonDecode(File('../test/protocol/manifest-v1.json').readAsStringSync())
          as List;
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
