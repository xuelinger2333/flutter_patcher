import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:path/path.dart' as p;
import '../core.dart';

Uint8List hexBytes(String text) => Uint8List.fromList([
      for (var i = 0; i < text.length; i += 2)
        int.parse(text.substring(i, i + 2), radix: 16)
    ]);

Future<List<int>> signingKey(String raw, String work, Commands commands,
    {String? expectedPublic}) async {
  List<int> seed;
  try {
    seed = base64Decode(raw.trim());
  } catch (_) {
    throw Failure('PATCH_KEY_INVALID', 'Expected base64 Ed25519 seed');
  }
  require(
      seed.length == 32, 'PATCH_KEY_INVALID', 'Ed25519 seed must be 32 bytes');
  final key = [...hexBytes('302e020100300506032b657004220420'), ...seed],
      pub = p.join(work, 'signing-public.der');
  await commands.run(
      'openssl',
      [
        'pkey',
        '-inform',
        'DER',
        '-in',
        '/dev/stdin',
        '-pubout',
        '-outform',
        'DER',
        '-out',
        pub
      ],
      inputBytes: key,
      code: 'PATCH_KEY_INVALID');
  final bytes = await File(pub).readAsBytes();
  require(
      bytes.length == 44 &&
          bytes.take(12).join(',') ==
              hexBytes('302a300506032b6570032100').join(','),
      'PATCH_KEY_INVALID',
      'Unexpected Ed25519 public key');
  final public = base64Encode(bytes.sublist(12));
  require(expectedPublic == null || public == expectedPublic,
      'PATCH_KEY_MISMATCH', 'Signing key does not match the release bootstrap');
  return key;
}

Future<void> verifyMessage(List<int> message, List<int> signature,
    String public, String work, Commands commands) async {
  final raw = base64Decode(public.trim());
  require(raw.length == 32 && signature.length == 64,
      'PUBLISH_SIGNATURE_INVALID', 'Key/signature size');
  await Directory(work).create(recursive: true);
  final input = p.join(work, 'message.bin'),
      sig = p.join(work, 'signature.bin'),
      pub = p.join(work, 'verify.der');
  await File(input).writeAsBytes(message);
  await File(sig).writeAsBytes(signature);
  await File(pub)
      .writeAsBytes([...hexBytes('302a300506032b6570032100'), ...raw]);
  try {
    await commands.run('openssl', [
      'pkeyutl',
      '-verify',
      '-rawin',
      '-pubin',
      '-inkey',
      pub,
      '-keyform',
      'DER',
      '-in',
      input,
      '-sigfile',
      sig
    ]);
  } catch (_) {
    throw Failure('PUBLISH_SIGNATURE_INVALID', 'Signature verification failed');
  }
}

Future<List<int>> signMessage(List<int> message, String seed,
    String expectedPublic, String work, Commands commands) async {
  await Directory(work).create(recursive: true);
  try {
    final key =
        await signingKey(seed, work, commands, expectedPublic: expectedPublic);
    final input = p.join(work, 'message.bin'),
        sig = p.join(work, 'signature.bin');
    await File(input).writeAsBytes(message);
    await commands.run(
        'openssl',
        [
          'pkeyutl',
          '-sign',
          '-rawin',
          '-inkey',
          '/dev/stdin',
          '-keyform',
          'DER',
          '-in',
          input,
          '-out',
          sig
        ],
        inputBytes: key);
    final signature = await File(sig).readAsBytes();
    await verifyMessage(message, signature, expectedPublic, work, commands);
    return signature;
  } catch (_) {
    throw Failure('PUBLISH_SIGN_FAILED',
        'Signing failed; verify configured key pair and OpenSSL');
  }
}
