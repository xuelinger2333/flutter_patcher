import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:flutter_patcher/src/bootstrap/patch_archive.dart';
import 'package:flutter_patcher/src/bootstrap/runner.dart';

final fp = 'ab' * 32;
Uint8List envelope(
    {bool fonts = false, bool assets = false, String extra = ''}) {
  final module = Uint8List(120);
  ByteData.sublistView(module).setUint32(0, 0x44424333, Endian.little);
  Map<String, Object> row(String path, List<int> bytes) => {
        'path': path,
        'length': bytes.length,
        'sha256': sha256.convert(bytes).toString()
      };
  final manifest = {
    'format_version': 1,
    'patch_seq': 7,
    'fingerprint': fp,
    'tier': 'lean',
    'module': row('module.bc', module),
    'assets': [
      if (assets)
        {
          ...row('assets/a', [1]),
          'key': 'a'
        }
    ],
    'fonts': [
      if (fonts)
        {
          ...row('fonts/a', [2]),
          'family': 'Family'
        }
    ]
  };
  final files = {
    'module.bc': module,
    'patch_manifest.json': utf8.encode(jsonEncode(manifest)),
    if (assets) 'assets/a': [1],
    if (fonts) 'fonts/a': [2],
    if (extra.isNotEmpty) extra: [3]
  };
  final archive = Archive();
  for (final row in files.entries) {
    archive.addFile(ArchiveFile(row.key, row.value.length, row.value)
      ..compression = CompressionType.none);
  }
  final zip = ZipEncoder().encode(archive, level: 0);
  final header = ByteData(146)
    ..setUint32(0, 0x46505443)
    ..setUint16(4, 1)
    ..setUint32(38, 7)
    ..setUint64(42, zip.length);
  final bytes = header.buffer.asUint8List();
  bytes.fillRange(6, 38, 0xab);
  bytes.setRange(50, 82, sha256.convert(zip).bytes);
  // Signature verification is native; this test supplies its exact-byte hash.
  return Uint8List.fromList([...bytes, ...zip]);
}

void main() {
  test('codec snapshot survives source file replacement before parsing', () {
    final directory = Directory.systemTemp.createTempSync('boot-snapshot-');
    try {
      final file = File('${directory.path}/candidate.fptc');
      file.writeAsBytesSync(envelope(assets: true));
      final authenticated = file.readAsBytesSync();
      const codec = StandardMethodCodec();
      final encoded = codec.encodeSuccessEnvelope({
        'transportVersion': 1,
        'attempt': 'token',
        'envelopeBytes': authenticated
      });
      file.writeAsBytesSync([0, 1, 2]);
      authenticated.fillRange(0, authenticated.length, 0);
      final reply = codec.decodeEnvelope(encoded) as Map;
      final patch =
          parseAuthenticatedPatchBytes(reply['envelopeBytes'] as Uint8List, fp);
      expect(patch.assets['a'], [1]);
      expect(patch.seq, 7);
    } finally {
      directory.deleteSync(recursive: true);
    }
  });
  test('reads the real CLI STORED encoding and validates all resource digests',
      () {
    final bytes = envelope(assets: true, fonts: true);
    final patch = verifyPatchBytes(bytes, fp, sha256.convert(bytes).toString());
    expect(patch.assets['a'], [1]);
    expect(patch.fonts['Family'], [
      [2]
    ]);
    final changed = Uint8List.fromList(bytes)..[82] ^= 1;
    expect(
        () => verifyPatchBytes(changed, fp, sha256.convert(bytes).toString()),
        throwsFormatException);
  });
  test('rejects traversal, unlisted entries, truncation and payload corruption',
      () {
    for (final bytes in [
      envelope(extra: '../x'),
      envelope(extra: 'x'),
      Uint8List(90),
      Uint8List.fromList(envelope())..[147] ^= 1
    ]) {
      expect(
          () => verifyPatchBytes(bytes, fp, sha256.convert(bytes).toString()),
          throwsFormatException);
    }
  });
  for (final scenario in [
    'good',
    'missing',
    'legacy',
    'wrong-version',
    'wrong-bytes',
    'expired',
    'timeout',
    'bad-entry',
    'bad-types',
    'async-error',
    'loader',
    'font',
    'main'
  ]) {
    test('startup $scenario has one main and attempt-bound reporting',
        () async {
      final bytes = envelope(assets: true, fonts: scenario == 'font');
      final calls = <String>[], events = <String>[];
      final logs = <String>[];
      Future<void> Function()? firstFrame;
      Future<void> Function(Object)? failure;
      final late = Completer<Object?>();
      final runner = BootRunner(
          timeout: const Duration(milliseconds: 10),
          call: (method, args) async {
            calls.add(method);
            if (method == 'bootPayload') {
              if (scenario == 'missing') return null;
              if (scenario == 'timeout') return late.future;
              if (scenario == 'legacy')
                return {
                  'attempt': 'token',
                  'path': 'file',
                  'sha256': sha256.convert(bytes).toString()
                };
              if (scenario == 'wrong-version')
                return {
                  'attempt': 'token',
                  'transportVersion': 2,
                  'envelopeBytes': bytes
                };
              if (scenario == 'wrong-bytes')
                return {
                  'attempt': 'token',
                  'transportVersion': 1,
                  'envelopeBytes': bytes.toList()
                };
              return {
                'attempt': 'token',
                'transportVersion': 1,
                'envelopeBytes': bytes
              };
            }
            expect(args['attempt'], 'token');
            if (scenario == 'expired' && method == 'markBooting') return false;
            if (method == 'reportDartBootError') {
              expect(
                  args['quarantine'], scenario == 'font' || scenario == 'main');
            }
            return true;
          },
          load: (_) async {
            events.add('load');
            if (scenario == 'loader') throw StateError('loader');
            if (scenario == 'bad-entry') return [1];
            if (scenario == 'async-error') await failure!(StateError('async'));
            return [
              scenario == 'bad-types' ? 1.0 : 1,
              7,
              fp,
              'lean',
              () {
                events.add('patched');
                if (scenario == 'main') throw StateError('main');
              },
              (Map<String, Uint8List> assets) {
                events.add('assets');
              }
            ];
          },
          fonts: (_) async {
            events.add('fonts');
            throw StateError('font');
          },
          observe: (onError, success) {
            failure = onError;
            firstFrame = success;
          },
          log: (message) => logs.add(message.toString()));
      await runner.run(
          original: () {
            events.add('original');
          },
          fingerprint: fp,
          publicKeyBase64: 'key');
      if (scenario == 'timeout') {
        late.complete(
            {'attempt': 'late', 'transportVersion': 1, 'envelopeBytes': bytes});
        await Future<void>.delayed(Duration.zero);
      }
      await firstFrame?.call();
      expect(calls.where((c) => c == 'reportDartBootError').length,
          lessThanOrEqualTo(1));
      if (scenario == 'good') {
        expect(events, ['load', 'assets', 'patched']);
        final timing = logs
            .singleWhere((line) => line.startsWith('BYTECODE_BOOT_TIMING:'));
        final values = RegExp(r'\w+_us=(\d+)')
            .allMatches(timing)
            .map((m) => int.parse(m.group(1)!))
            .toList();
        expect(values.length, 5);
        expect(values.take(4).fold<int>(0, (sum, value) => sum + value),
            values.last);
        expect(calls.last, 'reportBootSuccess');
      } else if (scenario == 'main' || scenario == 'font') {
        expect(events, isNot(contains('original')));
        expect(calls.last, 'reportDartBootError');
      } else {
        expect(events.where((e) => e == 'original').length, 1);
        expect(calls, isNot(contains('reportBootSuccess')));
      }
    });
  }
}
