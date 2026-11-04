import 'dart:convert';
import 'dart:typed_data';

import '../core.dart';
import 'ed25519.dart';

Uint8List hexBytes(String text) => Uint8List.fromList([
  for (var i = 0; i < text.length; i += 2)
    int.parse(text.substring(i, i + 2), radix: 16),
]);

void verifyMessage(List<int> message, List<int> signature, String public) {
  List<int> raw;
  try {
    raw = base64Decode(public.trim());
  } catch (_) {
    throw Failure('PUBLISH_SIGNATURE_INVALID', 'Public key encoding');
  }
  require(
    raw.length == 32 && signature.length == 64,
    'PUBLISH_SIGNATURE_INVALID',
    'Key/signature size',
  );
  require(
    ed25519Verify(raw, signature, message),
    'PUBLISH_SIGNATURE_INVALID',
    'Signature verification failed',
  );
}
