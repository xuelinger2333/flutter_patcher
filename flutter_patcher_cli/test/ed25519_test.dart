import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'host_tools.dart';
import 'package:flutter_patcher_cli/src/crypto/ed25519.dart';
import 'package:flutter_patcher_cli/src/crypto/signing.dart';

/// RFC 8032 §7.1 test vectors 1–3.
const rfcVectors = [
  (
    seed: '9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60',
    public: 'd75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a',
    message: '',
    signature:
        'e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b',
  ),
  (
    seed: '4ccd089b28ff96da9db6c346ec114e0f5b8a319f35aba624da8cf6ed4fb8a6fb',
    public: '3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c',
    message: '72',
    signature:
        '92a009a9f0d4cab8720e820b5f642540a2b27b5416503f8fb3762223ebdb69da085ac1e43e15996e458f3613d0f11d8c387b2eaeb4302aeeb00d291612bb0c00',
  ),
  (
    seed: 'c5aa8df43f9f837bedb7442f31dcb7b166d38535076f094b85ce3a2e0b4458f7',
    public: 'fc51cd8e6218a1a38da47ed00230f0580816ed13ba3303ac5deb911548908025',
    message: 'af82',
    signature:
        '6291d657deec24024827e69c3abe01a30ce548a284743a445e3680d7db5ac3ac18ff9b538d16f290ae67f760984dc6594a7c15e9716ed28dc027beceea1ec40a',
  ),
];

void main() {
  test('RFC 8032 vectors: key derivation, signing and verification', () {
    for (final v in rfcVectors) {
      final seed = hexBytes(v.seed), message = hexBytes(v.message);
      expect(ed25519PublicKey(seed), hexBytes(v.public));
      final signature = ed25519Sign(seed, message);
      expect(signature, hexBytes(v.signature));
      expect(ed25519Verify(hexBytes(v.public), signature, message), isTrue);
    }
  });

  test('tampered signature, message or key is rejected', () {
    final v = rfcVectors[2];
    final seed = hexBytes(v.seed), message = hexBytes(v.message);
    final public = hexBytes(v.public), signature = ed25519Sign(seed, message);
    for (var i = 0; i < 64; i += 7) {
      final bad = List<int>.from(signature)..[i] ^= 1;
      expect(ed25519Verify(public, bad, message), isFalse, reason: 'byte $i');
    }
    expect(ed25519Verify(public, signature, [...message, 0]), isFalse);
    expect(ed25519Verify(List<int>.from(public)..[0] ^= 1, signature, message),
        isFalse);
    expect(ed25519Verify(public, signature.sublist(1), message), isFalse);
    expect(ed25519Verify(public.sublist(1), signature, message), isFalse);
  });

  test('non-canonical s, identity and small-order public keys are rejected',
      () {
    final v = rfcVectors[0];
    final seed = hexBytes(v.seed), public = hexBytes(v.public);
    final signature = ed25519Sign(seed, const []);
    // s + L is a valid but non-canonical scalar; strict verifiers reject it.
    final order = (BigInt.one << 252) +
        BigInt.parse('27742317777372353535851937790883648493');
    var s = BigInt.zero;
    for (var i = 63; i >= 32; i--) {
      s = (s << 8) | BigInt.from(signature[i]);
    }
    final malleable = List<int>.from(signature);
    var t = s + order;
    for (var i = 32; i < 64; i++) {
      malleable[i] = (t & BigInt.from(0xff)).toInt();
      t >>= 8;
    }
    expect(ed25519Verify(public, malleable, const []), isFalse);
    final identity = List<int>.filled(32, 0)..[0] = 1;
    expect(ed25519Verify(identity, signature, const []), isFalse);
    final smallOrder = List<int>.filled(32, 0); // y = 0, order 4
    expect(ed25519Verify(smallOrder, signature, const []), isFalse);
    final nonCanonicalY = List<int>.filled(32, 0xff)..[31] = 0x7f; // y >= p
    expect(ed25519Verify(nonCanonicalY, signature, const []), isFalse);
  });

  test('generated seeds are 32 bytes, distinct, and round-trip', () {
    final a = ed25519GenerateSeed(), b = ed25519GenerateSeed();
    expect(a.length, 32);
    expect(a, isNot(b));
    final message = utf8.encode('flutter_patcher');
    expect(ed25519Verify(ed25519PublicKey(a), ed25519Sign(a, message), message),
        isTrue);
  });

  test('signMessage reproduces the shared protocol vectors', () {
    final vectors =
        jsonDecode(File('../test/protocol/manifest-v1.json').readAsStringSync())
            as List;
    final seed = base64Encode(hexBytes(rfcVectors[0].seed));
    final public = base64Encode(hexBytes(rfcVectors[0].public));
    var checked = 0;
    for (final vector in vectors.cast<Map>()) {
      if (vector['tamper'] == true ||
          vector['public_key'] != rfcVectors[0].public) {
        continue;
      }
      final message = hexBytes(vector['signing_hex'] as String);
      final expected = hexBytes(vector['signature'] as String);
      if (!ed25519Verify(
          hexBytes(vector['public_key'] as String), expected, message)) {
        continue; // tampered vectors carry a deliberately broken signature
      }
      expect(signMessage(message, seed, public), expected,
          reason: vector['name']);
      checked++;
    }
    expect(checked, greaterThan(20));
  });

  test('OpenSSL verifies what we sign and we verify what OpenSSL signs',
      () async {
    final temp = await Directory.systemTemp.createTemp('ed25519-');
    addTearDown(() => temp.delete(recursive: true));
    final v = rfcVectors[1];
    final seed = hexBytes(v.seed), public = hexBytes(v.public);
    final message = utf8.encode('cross-check ${DateTime.now()}');
    final pkcs8 = p.join(temp.path, 'key.der'),
        spki = p.join(temp.path, 'pub.der');
    await File(pkcs8).writeAsBytes(
        [...hexBytes('302e020100300506032b657004220420'), ...seed]);
    await File(spki)
        .writeAsBytes([...hexBytes('302a300506032b6570032100'), ...public]);
    final input = p.join(temp.path, 'message.bin');
    await File(input).writeAsBytes(message);
    final ours = p.join(temp.path, 'ours.sig');
    await File(ours).writeAsBytes(ed25519Sign(seed, message));
    final verify = await Process.run('openssl', [
      'pkeyutl', '-verify', '-rawin', '-pubin', '-inkey', spki, '-keyform',
      'DER', '-in', input, '-sigfile', ours, //
    ]);
    expect(verify.exitCode, 0, reason: '${verify.stderr}${verify.stdout}');
    final theirs = p.join(temp.path, 'theirs.sig');
    final sign = await Process.run('openssl', [
      'pkeyutl', '-sign', '-rawin', '-inkey', pkcs8, '-keyform', 'DER', '-in',
      input, '-out', theirs, //
    ]);
    expect(sign.exitCode, 0, reason: '${sign.stderr}');
    expect(await File(theirs).readAsBytes(), ed25519Sign(seed, message));
  }, tags: 'openssl', skip: skipUnless('openssl') ?? false);
}
