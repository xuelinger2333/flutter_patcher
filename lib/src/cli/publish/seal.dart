import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:archive/archive.dart';

import '../core.dart';
import '../crypto/ed25519.dart';
import '../keys/bundle.dart';
import '../keys/signer.dart';
import '../patch/package.dart';

/// Seals [draft] as the FPTC v1 file devices install, numbered [seq] and
/// signed by [signer], or unsigned for a host that trusts no key.
/// Ed25519 is deterministic: the same draft, sequence and key give the same bytes.
Future<Uint8List> sealPatch(
  PatchDraft draft, {
  Signer? signer,
  required int seq,
}) async {
  checkSeq(seq);
  final manifest = {...draft.manifest}..remove('draft_version');
  manifest['patch_seq'] = seq;
  final archive = ZipDecoder().decodeBytes(draft.payload);
  final payload = plainZip(
    {
      for (final file in archive)
        file.name: file.name == 'patch_manifest.json'
            ? utf8.encode(jsonEncode(manifest))
            : file.content as List<int>,
    },
    deflated: (manifest['code'] as Map)['kind'] == 'libapp'
        ? 'libapp.so'
        : null,
  );
  return _seal(draft.fingerprint, seq, payload, signer);
}

/// A withdrawal of the host [fingerprint]: a file with no payload. Devices
/// drop their patch and accept only files numbered above [seq].
Future<Uint8List> sealWithdrawal(
  String fingerprint, {
  Signer? signer,
  required int seq,
}) {
  checkSeq(seq);
  return _seal(fingerprint, seq, const [], signer);
}

void checkSeq(int seq) => require(
  seq > 0 && seq <= 0xffffffff,
  'PUBLISH_SEQUENCE_CONFLICT',
  'Sequence must be between 1 and 4294967295.',
);

Future<Uint8List> _seal(
  String fingerprint,
  int seq,
  List<int> payload,
  Signer? signer,
) async {
  require(
    signer == null || signer.role == KeyRole.patch,
    'KEYS_MISMATCH',
    'Patch files are signed with the patch key.',
  );
  final header = ByteData(82)
    ..setUint32(0, 0x46505443)
    ..setUint16(4, 1);
  header.buffer.asUint8List().setRange(6, 38, hexBytes(fingerprint));
  header.setUint32(38, seq);
  header.setUint64(42, payload.length);
  header.buffer.asUint8List().setRange(50, 82, sha256.convert(payload).bytes);
  final head = header.buffer.asUint8List();
  var signature = Uint8List(64);
  if (signer != null) {
    final signed = [...head, ...payload];
    signature = await signer.sign(signed);
    require(
      ed25519Verify(base64Decode(signer.publicKey), signature, signed),
      'PATCH_SIGN_FAILED',
      'Signature self-check failed',
    );
  }
  return Uint8List.fromList([...head, ...signature, ...payload]);
}
