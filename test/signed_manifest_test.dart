import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_patcher/src/signed_manifest.dart';

void main() {
  final vectors =
      jsonDecode(File('test/protocol/manifest-v1.json').readAsStringSync())
          as List;
  for (final row in vectors.cast<Map<String, dynamic>>()) {
    test(row['name'] as String, () {
      if (row['envelope_valid'] != true) {
        expect(() => SignedManifest.parse(row['wire'] as String),
            throwsFormatException);
      } else {
        final envelope = SignedManifest.parse(row['wire'] as String);
        expect(envelope.payload, base64.decode(row['payload'] as String));
        final original = envelope.payload.first;
        envelope.payload[0] ^= 1;
        expect(envelope.payload.first, original);
        // Bad signatures remain untrusted data, not a Dart authentication result.
        expect(envelope.wire, row['wire']);
      }
    });
  }
}
