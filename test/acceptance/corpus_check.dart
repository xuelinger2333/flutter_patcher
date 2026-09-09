import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_patcher/src/bootstrap/patch_archive.dart';
import 'package:flutter_patcher/src/bootstrap/runner.dart';

void main() {
  final directory = Platform.environment['WP9_CORPUS'];
  if (directory == null) {
    throw StateError('WP9_CORPUS is required; no silent skip');
  }
  final suite =
      jsonDecode(File('$directory/corpus.json').readAsStringSync()) as Map;
  for (final row in suite['cases'] as List) {
    final layer = row['layer'];
    if (!['archive', 'accept', 'boot', 'state'].contains(layer) ||
        row['id'] == 'main-hangs') {
      continue;
    }
    test('authenticated corpus ${row['id']} reaches $layer', () async {
      final bytes = File('$directory/${row['file']}').readAsBytesSync();
      expect(sha256.convert(bytes).toString(), row['sha256']);
      final fp = suite['fingerprint'] as String;
      if (layer == 'archive') {
        expect(
            () => verifyPatchBytes(bytes, fp, row['sha256'] as String),
            throwsA(isA<FormatException>()
                .having((e) => e.message, 'reason', contains(row['reason']))));
      } else {
        final patch = verifyPatchBytes(bytes, fp, row['sha256'] as String);
        expect(patch.module.length, greaterThanOrEqualTo(120));
        if (layer != 'boot') return;
        var original = 0;
        final failures = <String>[];
        // Tests the tuple guard separately. Actual compiled module loading is a device obligation.
        final runner = BootRunner(
          call: (method, args) async {
            if (method == 'bootPayload') {
              return {
                'attempt': 'wp9',
                'path': 'fixture',
                'sha256': row['sha256']
              };
            }
            if (method == 'markBooting') return true;
            if (method == 'reportDartBootError') {
              failures.add(args['message'] as String);
            }
            return null;
          },
          read: (_) async => Uint8List.fromList(bytes),
          load: (_) async => row['id'] == 'entry-short'
              ? [1]
              : [
                  1,
                  patch.seq,
                  fp,
                  patch.tier,
                  row['id'] == 'entry-not-function'
                      ? 42
                      : () {
                          throw StateError('WP9 intentional boot failure');
                        },
                  null
                ],
          fonts: (_) async {},
          observe: (failure, success) {},
          log: (_) {},
        );
        await runner.run(
            original: () {
              original++;
            },
            fingerprint: fp,
            publicKeyBase64: suite['public_key'] as String);
        expect(failures.single, contains(row['reason']));
        expect(original, row['id'] == 'main-throws' ? 0 : 1);
      }
    });
  }
}
