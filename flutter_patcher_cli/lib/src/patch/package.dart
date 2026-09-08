import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import '../core.dart';
import 'resources.dart';

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

Future<Map<String, Object?>> packPatch(
    {required String module,
    required String work,
    required Map<String, dynamic> metadata,
    required List<int> key,
    required Commands commands,
    Map<String, List<int>> extraEntries = const {},
    List<Map<String, dynamic>> fonts = const [],
    List<Map<String, dynamic>> assets = const []}) async {
  final bytes = await File(module).readAsBytes();
  require(
      extraEntries.length <= 4094 &&
          extraEntries.values.every((v) => v.length <= 64 * 1024 * 1024) &&
          bytes.length +
                  extraEntries.values.fold<int>(0, (n, v) => n + v.length) <=
              256 * 1024 * 1024,
      'PATCH_PACKAGE_INVALID',
      'Patch payload exceeds resource limits');
  for (final row in assets) {
    assetKey(row['key'] as String);
    require(row['path'] == 'assets/${row['key']}', 'PATCH_PACKAGE_INVALID',
        'Asset key/path mismatch');
  }
  for (final row in fonts) {
    require(
        row['family'] is String &&
            (row['family'] as String).isNotEmpty &&
            (row['path'] as String).startsWith('fonts/'),
        'PATCH_PACKAGE_INVALID',
        'Invalid font metadata');
  }
  final listed = <String>{};
  for (final row in [...fonts, ...assets]) {
    final path = row['path'] as String;
    assetKey(path);
    require(
        (path.startsWith('fonts/') || path.startsWith('assets/')) &&
            listed.add(path) &&
            extraEntries.containsKey(path),
        'PATCH_PACKAGE_INVALID',
        'Invalid resource entry');
    final data = extraEntries[path]!;
    require(
        data.length == row['length'] &&
            sha256.convert(data).toString() == row['sha256'],
        'PATCH_PACKAGE_INVALID',
        'Resource metadata does not match bytes');
  }
  require(listed.length == extraEntries.length, 'PATCH_PACKAGE_INVALID',
      'Unlisted resource entry');
  require(bytes.isNotEmpty && bytes.length <= 64 * 1024 * 1024,
      'PATCH_PACKAGE_INVALID', 'Invalid bytecode size');
  final manifest = {
    ...metadata,
    'module': {
      'path': 'module.bc',
      'length': bytes.length,
      'sha256': sha256.convert(bytes).toString()
    },
    'fonts': fonts,
    'assets': assets
  };
  final archive = Archive();
  for (final entry in {
    'module.bc': bytes,
    'patch_manifest.json': utf8.encode(jsonEncode(manifest)),
    ...extraEntries
  }.entries) {
    archive.addFile(ArchiveFile(entry.key, entry.value.length, entry.value)
      ..compression = CompressionType.none);
  }
  final payload = ZipEncoder().encode(archive, level: 0);
  final zip = ZipDecoder().decodeBytes(payload);
  require(
      zip.length == 2 + extraEntries.length &&
          zip.length <= 4096 &&
          zip.every((f) => f.size <= 64 * 1024 * 1024) &&
          zip.every((f) => f.compression == CompressionType.none),
      'PATCH_PACKAGE_INVALID',
      'Only STORED entries are allowed');
  final header = ByteData(82)
    ..setUint32(0, 0x46505443)
    ..setUint16(4, 1);
  header.buffer
      .asUint8List()
      .setRange(6, 38, hexBytes(metadata['fingerprint'] as String));
  header.setUint32(38, metadata['patch_seq'] as int);
  header.setUint64(42, payload.length);
  header.buffer.asUint8List().setRange(50, 82, sha256.convert(payload).bytes);
  final signed = p.join(work, 'signed.bin'),
      sig = p.join(work, 'signature.bin');
  await File(signed).writeAsBytes([...header.buffer.asUint8List(), ...payload]);
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
        signed,
        '-out',
        sig
      ],
      inputBytes: key,
      code: 'PATCH_SIGN_FAILED');
  final signature = await File(sig).readAsBytes();
  require(
      signature.length == 64, 'PATCH_SIGN_FAILED', 'Invalid signature length');
  await commands.run(
      'openssl',
      [
        'pkeyutl',
        '-verify',
        '-rawin',
        '-pubin',
        '-inkey',
        p.join(work, 'signing-public.der'),
        '-keyform',
        'DER',
        '-in',
        signed,
        '-sigfile',
        sig
      ],
      code: 'PATCH_SIGN_FAILED');
  final output = p.join(work, 'patch.fptc');
  await File(output)
      .writeAsBytes([...header.buffer.asUint8List(), ...signature, ...payload]);
  return {
    'file': output,
    'sha256': await hashFile(output),
    'bytes': await File(output).length(),
    'manifest': manifest
  };
}
