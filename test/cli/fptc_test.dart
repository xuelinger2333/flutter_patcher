import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'package:flutter_patcher/src/bootstrap/patch_archive.dart';
import 'package:flutter_patcher/src/cli/core.dart';
import 'package:flutter_patcher/src/cli/crypto/ed25519.dart';
import 'package:flutter_patcher/src/cli/patch/package.dart';
import 'package:flutter_patcher/src/cli/publish/seal.dart';
import 'package:flutter_patcher/src/patch_file.dart';

import 'signers.dart';

/// FPTC v1.
void main() {
  final vectors =
      jsonDecode(File('test/protocol/fptc-v1.json').readAsStringSync()) as Map;
  final seed = base64Encode(
    List.generate(32, (i) => i + 1),
  ); // a test seed, never a real key
  final signer = testSigner(seed);
  final fingerprint = 'ab' * 32;

  late PatchDraft draft;
  setUpAll(() async {
    final root = (await Directory.systemTemp.createTemp('fptc-')).path;
    final module = File(p.join(root, 'module.bc'))
      ..writeAsStringSync('synthetic bytecode for the file format only');
    draft = await packPatch(
      kind: 'bytecode',
      code: module.path,
      metadata: {'fingerprint': fingerprint, 'module_id': 9, 'tier': 'lean'},
    );
  });

  void expectHeader(Uint8List bytes, {required int seq, required int length}) {
    final view = ByteData.sublistView(bytes);
    expect(bytes.length, patchHeaderSize + length);
    expect(view.getUint32(0), 0x46505443);
    expect(view.getUint16(4), 1);
    expect(hex(bytes.sublist(6, 38)), fingerprint);
    expect(view.getUint32(38), seq);
    expect(view.getUint64(42), length);
    expect(
      hex(bytes.sublist(50, 82)),
      sha256.convert(bytes.sublist(patchHeaderSize)).toString(),
    );
  }

  group('a patch file', () {
    test('without a signer has a zero signature', () async {
      final bytes = await sealPatch(draft, seq: 1793520000);
      expectHeader(bytes, seq: 1793520000, length: bytes.length - 146);
      expect(bytes.sublist(82, 146), List.filled(64, 0));
    });

    test('with the patch key is signed over its header and payload', () async {
      final bytes = await sealPatch(draft, signer: signer, seq: 7);
      expectHeader(bytes, seq: 7, length: bytes.length - 146);
      expect(
        ed25519Verify(base64Decode(signer.publicKey), bytes.sublist(82, 146), [
          ...bytes.sublist(0, 82),
          ...bytes.sublist(146),
        ]),
        isTrue,
      );
    });

    test('is the same bytes for the same draft, sequence and key', () async {
      expect(
        await sealPatch(draft, signer: signer, seq: 7),
        await sealPatch(draft, signer: signer, seq: 7),
      );
    });

    test('records its sequence in the patch manifest it carries', () async {
      final bytes = await sealPatch(draft, seq: 7);
      final manifest = readPatchArchive(
        Uint8List.sublistView(bytes, 146),
      )['patch_manifest.json']!;
      expect((jsonDecode(utf8.decode(manifest)) as Map)['patch_seq'], 7);
      expect(draft.manifest.containsKey('patch_seq'), isFalse);
    });

    test('refuses a sequence outside 1 to 4294967295', () async {
      for (final seq in [0, 0x100000000]) {
        await expectLater(
          sealPatch(draft, seq: seq),
          throwsA(
            isA<Failure>().having(
              (f) => f.code,
              'code',
              'PUBLISH_SEQUENCE_CONFLICT',
            ),
          ),
        );
      }
    });
  });

  group('a withdrawal', () {
    test('is a header with no payload', () async {
      final bytes = await sealWithdrawal(fingerprint, seq: 8);
      expectHeader(bytes, seq: 8, length: 0);
      expect(bytes.sublist(82, 146), List.filled(64, 0));
    });

    test('with the patch key is signed over its header', () async {
      final bytes = await sealWithdrawal(fingerprint, signer: signer, seq: 8);
      expect(
        ed25519Verify(
          base64Decode(signer.publicKey),
          bytes.sublist(82, 146),
          bytes.sublist(0, 82),
        ),
        isTrue,
      );
    });
  });

  group('the shared vectors', () {
    for (final row in (vectors['files'] as List).cast<Map>()) {
      final bytes = base64Decode(row['file'] as String);
      if (row['valid'] != true) continue;
      test('${row['name']}: the header reads back', () {
        final header = PatchHeader.parse(bytes);
        expect(header.seq, row['seq']);
        expect(header.fingerprint, row['fingerprint']);
        expect(header.withdrawal, row['action'] == 'withdraw');
        expect(header.fileLength, bytes.length);
      });
    }

    for (final row in (vectors['file_names'] as List).cast<Map>()) {
      test('file name ${row['file_name']}', () {
        expect(
          patchFileName((row['scope'] as Map).cast<String, String>()),
          row['file_name'],
        );
      });
    }
  });

  group('a header', () {
    test('needs 146 bytes, the FPTC magic and version 1', () async {
      final bytes = await sealWithdrawal(fingerprint, seq: 8);
      expect(
        () => PatchHeader.parse(bytes.sublist(0, 145)),
        throwsFormatException,
      );
      for (final offset in [0, 5]) {
        expect(
          () => PatchHeader.parse(Uint8List.fromList(bytes)..[offset] ^= 1),
          throwsFormatException,
        );
      }
    });

    test('reads from its first 146 bytes alone', () async {
      final bytes = await sealPatch(draft, seq: 7);
      final header = PatchHeader.parse(bytes.sublist(0, 146));
      expect(header.seq, 7);
      expect(header.withdrawal, isFalse);
      expect(header.fileLength, bytes.length);
      expect(
        header.payloadSha256,
        sha256.convert(bytes.sublist(146)).toString(),
      );
    });
  });
}

String hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
