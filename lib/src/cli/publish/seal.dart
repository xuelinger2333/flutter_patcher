import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../core.dart';
import '../crypto/ed25519.dart';
import '../keys/bundle.dart';
import '../keys/signer.dart';
import '../patch/package.dart';

/// Seals [draft] in a signed FPTC v1 envelope, the file devices download.
/// Ed25519 is deterministic: the same draft and key give the same bytes.
Future<Uint8List> sealPatch(PatchDraft draft, {required Signer signer}) async {
  require(
    signer.role == KeyRole.patch,
    'KEYS_MISMATCH',
    'Patch envelopes are signed with the patch key.',
  );
  final payload = draft.payload;
  final header = ByteData(82)
    ..setUint32(0, 0x46505443)
    ..setUint16(4, 1);
  header.buffer.asUint8List().setRange(6, 38, hexBytes(draft.fingerprint));
  header.setUint32(38, draft.seq);
  header.setUint64(42, payload.length);
  header.buffer.asUint8List().setRange(50, 82, sha256.convert(payload).bytes);
  final signed = [...header.buffer.asUint8List(), ...payload];
  final signature = await signer.sign(signed);
  require(
    ed25519Verify(base64Decode(signer.publicKey), signature, signed),
    'PATCH_SIGN_FAILED',
    'Signature self-check failed',
  );
  return Uint8List.fromList([
    ...header.buffer.asUint8List(),
    ...signature,
    ...payload,
  ]);
}
