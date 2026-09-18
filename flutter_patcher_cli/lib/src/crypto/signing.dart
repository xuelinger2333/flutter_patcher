import 'dart:convert';
import 'dart:typed_data';
import '../core.dart';
import 'ed25519.dart';

Uint8List hexBytes(String text) => Uint8List.fromList([
      for (var i = 0; i < text.length; i += 2)
        int.parse(text.substring(i, i + 2), radix: 16)
    ]);

/// Decodes the base64 seed and checks it against the release public key.
/// The seed only ever lives in memory; nothing is written to disk.
Uint8List signingKey(String raw, {String? expectedPublic}) {
  Uint8List seed;
  try {
    seed = base64Decode(raw.trim());
  } catch (_) {
    throw Failure('PATCH_KEY_INVALID', 'Expected base64 Ed25519 seed');
  }
  require(
      seed.length == 32, 'PATCH_KEY_INVALID', 'Ed25519 seed must be 32 bytes');
  final public = base64Encode(ed25519PublicKey(seed));
  require(expectedPublic == null || public == expectedPublic,
      'PATCH_KEY_MISMATCH', 'Signing key does not match the release bootstrap');
  return seed;
}

void verifyMessage(List<int> message, List<int> signature, String public) {
  List<int> raw;
  try {
    raw = base64Decode(public.trim());
  } catch (_) {
    throw Failure('PUBLISH_SIGNATURE_INVALID', 'Public key encoding');
  }
  require(raw.length == 32 && signature.length == 64,
      'PUBLISH_SIGNATURE_INVALID', 'Key/signature size');
  require(ed25519Verify(raw, signature, message), 'PUBLISH_SIGNATURE_INVALID',
      'Signature verification failed');
}

/// Signs and immediately re-verifies against the expected public key.
Uint8List signMessage(List<int> message, String seed, String expectedPublic) {
  try {
    final key = signingKey(seed, expectedPublic: expectedPublic);
    final signature = ed25519Sign(key, message);
    verifyMessage(message, signature, expectedPublic);
    return signature;
  } catch (_) {
    throw Failure('PUBLISH_SIGN_FAILED',
        'Signing failed; verify the configured key pair');
  }
}
