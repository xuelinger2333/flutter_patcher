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
Uint8List envelope({
  bool fonts = false,
  bool assets = false,
  String extra = '',
  String kind = 'bytecode',
  bool wrongEntryDigest = false,
}) {
  final module = Uint8List(120);
  ByteData.sublistView(module).setUint32(0, 0x44424333, Endian.little);
  Map<String, Object> row(String path, List<int> bytes) => {
    'path': path,
    'length': bytes.length,
    'sha256': sha256.convert(bytes).toString(),
  };
  final manifest = {
    'format_version': patchFormatVersion,
    'patch_seq': 7,
    'fingerprint': fp,
    'tier': 'lean',
    'code': {
      'kind': kind,
      ...row('module.bc', module),
      if (wrongEntryDigest) 'sha256': '0' * 64,
    },
    'assets': [
      if (assets)
        {
          ...row('assets/a', [1]),
          'key': 'a',
        },
    ],
    'fonts': [
      if (fonts)
        {
          ...row('fonts/a', [2]),
          'family': 'Family',
        },
    ],
  };
  final files = {
    'module.bc': module,
    'patch_manifest.json': utf8.encode(jsonEncode(manifest)),
    if (assets) 'assets/a': [1],
    if (fonts) 'fonts/a': [2],
    if (extra.isNotEmpty) extra: [3],
  };
  final archive = Archive();
  for (final row in files.entries) {
    archive.addFile(
      ArchiveFile(row.key, row.value.length, row.value)
        ..compression = CompressionType.none,
    );
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
  test('authenticated snapshot still rejects inconsistent entry metadata', () {
    final bytes = envelope(wrongEntryDigest: true);
    expect(
      () => parseAuthenticatedPatchBytes(bytes, fp),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'reason',
          'Entry digest',
        ),
      ),
    );
  });
  test(
    'authenticated snapshot still rejects matching but incorrect ZIP CRC fields',
    () {
      final bytes = envelope();
      final view = ByteData.sublistView(bytes);
      final central = 146 + view.getUint32(bytes.length - 6, Endian.little);
      final wrong = view.getUint32(146 + 14, Endian.little) ^ 1;
      view.setUint32(146 + 14, wrong, Endian.little);
      view.setUint32(central + 16, wrong, Endian.little);
      expect(
        () => parseAuthenticatedPatchBytes(bytes, fp),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'reason',
            'ZIP CRC mismatch',
          ),
        ),
      );
    },
  );
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
        'envelopeBytes': authenticated,
      });
      file.writeAsBytesSync([0, 1, 2]);
      authenticated.fillRange(0, authenticated.length, 0);
      final reply = codec.decodeEnvelope(encoded) as Map;
      final patch = parseAuthenticatedPatchBytes(
        reply['envelopeBytes'] as Uint8List,
        fp,
      );
      expect(patch.assets['a'], [1]);
      expect(patch.seq, 7);
    } finally {
      directory.deleteSync(recursive: true);
    }
  });
  test(
    'reads the real CLI STORED encoding and validates all resource digests',
    () {
      final bytes = envelope(assets: true, fonts: true);
      final patch = verifyPatchBytes(
        bytes,
        fp,
        sha256.convert(bytes).toString(),
      );
      expect(patch.assets['a'], [1]);
      expect(patch.fonts['Family'], [
        [2],
      ]);
      final changed = Uint8List.fromList(bytes)..[82] ^= 1;
      expect(
        () => verifyPatchBytes(changed, fp, sha256.convert(bytes).toString()),
        throwsFormatException,
      );
    },
  );
  test('rejects code that is not a bytecode module', () {
    final bytes = envelope(kind: 'libapp');
    expect(
      () => parseAuthenticatedPatchBytes(bytes, fp),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'reason',
          'Module path',
        ),
      ),
    );
  });
  group('SO host', () {
    Future<({List<String> calls, List<String> events})> boot(
      Map<String, Object?> payload, {
      bool failAssets = false,
    }) async {
      final calls = <String>[], events = <String>[];
      Future<void> Function()? firstFrame;
      final runner = BootRunner(
        call: (method, args) async {
          calls.add(method);
          if (method == 'bootPayload') return payload;
          expect(args['attempt'], 'token');
          return true;
        },
        assets: (assets) async {
          events.add('assets:${assets.keys.join(',')}');
          if (failAssets) throw StateError('engine');
        },
        fonts: (fonts) async => events.add('fonts:${fonts.keys.join(',')}'),
        observe: (_, success) => firstFrame = success,
        log: (_) {},
      );
      await runner.run(
        original: () => events.add('main'),
        fingerprint: fp,
        publicKeyBase64: 'key',
      );
      await firstFrame?.call();
      return (calls: calls, events: events);
    }

    Map<String, Object?> payload(Object? assets, Object? fonts) => {
      'attempt': 'token',
      'transportVersion': 1,
      'kind': 'libapp',
      'assets': assets,
      'fonts': fonts,
    };

    test('installs resources, then runs the running libapp main', () async {
      final run = await boot(
        payload(
          {
            'a': Uint8List.fromList([1]),
          },
          {
            'F': [
              Uint8List.fromList([2]),
            ],
          },
        ),
      );
      expect(run.events, ['assets:a', 'fonts:F', 'main']);
      expect(run.calls, ['bootPayload', 'markBooting', 'reportBootSuccess']);
    });
    test('a patch without resources only settles the attempt', () async {
      final run = await boot(payload(<String, Object?>{}, <String, Object?>{}));
      expect(run.events, ['main']);
      expect(run.calls.last, 'reportBootSuccess');
    });
    test('a failed install is reported and main still runs once', () async {
      final run = await boot(
        payload({
          'a': Uint8List.fromList([1]),
        }, <String, Object?>{}),
        failAssets: true,
      );
      expect(run.events, ['assets:a', 'main']);
      expect(run.calls, contains('reportDartBootError'));
      expect(run.calls, isNot(contains('reportBootSuccess')));
    });
    test('malformed resources fail before touching the engine', () async {
      final run = await boot(
        payload({
          'a': [1],
        }, <String, Object?>{}),
      );
      expect(run.events, ['main']);
      expect(run.calls, ['bootPayload', 'reportDartBootError']);
    });
  });
  group('background engine', () {
    const key = 'package:app/bg.dart#callback';
    void callback() {}
    ({BootRunner runner, List<String> calls, List<String> events}) runner(
      Object? payload, {
      Object? table,
    }) {
      final calls = <String>[], events = <String>[];
      return (
        runner: BootRunner(
          call: (method, args) async {
            calls.add(method);
            expect(args, {'fingerprint': fp, 'publicKeyBase64': 'key'});
            return payload;
          },
          load: (_) async {
            events.add('load');
            return [1, 7, fp, 'lean', () {}, table];
          },
          assets: (assets) async =>
              events.add('assets:${assets.keys.join(',')}'),
          fonts: (fonts) async => events.add('fonts:${fonts.keys.join(',')}'),
          observe: (_, _) => fail('A background boot observes nothing'),
          log: (_) {},
        ),
        calls: calls,
        events: events,
      );
    }

    Future<void> background(BootRunner runner) =>
        runner.background(fingerprint: fp, publicKeyBase64: 'key');

    test(
      'a bytecode isolate loads the module and keeps its entry points',
      () async {
        final run = runner(
          {'transportVersion': 1, 'envelopeBytes': envelope(assets: true)},
          table: {key: callback},
        );
        await background(run.runner);
        // Only the offer: no attempt is started, settled or failed.
        expect(run.calls, ['backgroundPayload']);
        expect(run.events, ['load', 'assets:a']);
        expect(run.runner.entries, {key: callback});
      },
    );
    test(
      'an SO isolate receives the resources of the running libapp',
      () async {
        final run = runner({
          'transportVersion': 1,
          'kind': 'libapp',
          'assets': {
            'a': Uint8List.fromList([1]),
          },
          'fonts': <String, Object?>{},
        });
        await background(run.runner);
        expect(run.calls, ['backgroundPayload']);
        expect(run.events, ['assets:a']);
        expect(run.runner.entries, isNull);
      },
    );
    test('no offer leaves the isolate as built', () async {
      final run = runner(null);
      await background(run.runner);
      expect(run.events, isEmpty);
      expect(run.runner.entries, isNull);
    });
    test('a module without entry points has an empty table', () async {
      final run = runner({'transportVersion': 1, 'envelopeBytes': envelope()});
      await background(run.runner);
      expect(run.runner.entries, isEmpty);
    });
    test('a malformed entry table or payload is rejected', () async {
      await expectLater(
        background(
          runner(
            {'transportVersion': 1, 'envelopeBytes': envelope()},
            table: {key: 1},
          ).runner,
        ),
        throwsA(anything),
      );
      await expectLater(
        background(runner({'envelopeBytes': envelope()}).runner),
        throwsA(anything),
      );
    });
  });
  group('patchEntry', () {
    const key = 'package:app/bg.dart#callback';
    final log = <String>[];
    Function? entry(
      Function? original, {
      required bool start,
      Map<String, Function>? entries,
      Future<void> Function()? boot,
    }) => patchEntry(
      key,
      original,
      start: start,
      entries: () => entries,
      boot: boot ?? () async {},
      log: (e) => log.add('$e'),
    );

    test('a looked-up callback is the loaded patch version', () {
      String original() => 'original';
      String patched() => 'patched';
      expect(entry(original, start: false), same(original));
      expect(entry(original, start: false, entries: {}), same(original));
      expect(
        entry(original, start: false, entries: {key: patched}),
        same(patched),
      );
      expect(entry(null, start: false, entries: {key: patched}), same(patched));
      expect(entry(null, start: false), isNull);
    });
    test('a starting entry point boots first, then runs the patch', () async {
      final events = <String>[];
      Map<String, Function>? entries;
      final start =
          entry(
                () => events.add('original'),
                start: true,
                entries: null,
                boot: () async => events.add('boot'),
              )
              as dynamic;
      // The engine calls it as it does a main: with the arguments, if any.
      expect(start, isA<Object? Function(List<String>)>());
      await start(['a']);
      expect(events, ['boot', 'original']);
      final patched =
          patchEntry(
                key,
                () => events.add('original'),
                start: true,
                entries: () => entries,
                boot: () async => entries = {
                  key: (List<String> args) => events.add('patched:$args'),
                },
                log: (_) {},
              )
              as dynamic;
      await patched(['b']);
      expect(events.last, 'patched:[b]');
      final nullary =
          patchEntry(
                key,
                null,
                start: true,
                entries: () => {key: () => events.add('nullary')},
                boot: () async {},
                log: (_) {},
              )
              as dynamic;
      await nullary(<String>[]);
      expect(events.last, 'nullary');
    });
    test('a failed boot runs the entry point as built', () async {
      final events = <String>[];
      final start =
          entry(
                () => events.add('original'),
                start: true,
                boot: () async => throw StateError('boot'),
              )
              as dynamic;
      await start(<String>[]);
      expect(events, ['original']);
      expect(log.last, contains('Background boot failed for $key'));
    });
    test('an entry point no code declares fails as the engine would', () async {
      final start = entry(null, start: true) as dynamic;
      await expectLater(start(<String>[]), throwsStateError);
    });
  });
  test(
    'rejects traversal, unlisted entries, truncation and payload corruption',
    () {
      for (final bytes in [
        envelope(extra: '../x'),
        envelope(extra: 'x'),
        Uint8List(90),
        Uint8List.fromList(envelope())..[147] ^= 1,
      ]) {
        expect(
          () => verifyPatchBytes(bytes, fp, sha256.convert(bytes).toString()),
          throwsFormatException,
        );
      }
    },
  );
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
    'main',
  ]) {
    test(
      'startup $scenario has one main and attempt-bound reporting',
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
              if (scenario == 'legacy') {
                return {
                  'attempt': 'token',
                  'path': 'file',
                  'sha256': sha256.convert(bytes).toString(),
                };
              }
              if (scenario == 'wrong-version') {
                return {
                  'attempt': 'token',
                  'transportVersion': 2,
                  'envelopeBytes': bytes,
                };
              }
              if (scenario == 'wrong-bytes') {
                return {
                  'attempt': 'token',
                  'transportVersion': 1,
                  'envelopeBytes': bytes.toList(),
                };
              }
              return {
                'attempt': 'token',
                'transportVersion': 1,
                'envelopeBytes': bytes,
              };
            }
            expect(args['attempt'], 'token');
            if (scenario == 'expired' && method == 'markBooting') return false;
            if (method == 'reportDartBootError') {
              expect(
                args['quarantine'],
                scenario == 'font' || scenario == 'main',
              );
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
              null,
            ];
          },
          assets: (assets) async {
            expect(assets['a'], [1]);
            events.add('assets');
          },
          fonts: (_) async {
            events.add('fonts');
            throw StateError('font');
          },
          observe: (onError, success) {
            failure = onError;
            firstFrame = success;
          },
          log: (message) => logs.add(message.toString()),
        );
        await runner.run(
          original: () {
            events.add('original');
          },
          fingerprint: fp,
          publicKeyBase64: 'key',
        );
        if (scenario == 'timeout') {
          late.complete({
            'attempt': 'late',
            'transportVersion': 1,
            'envelopeBytes': bytes,
          });
          await Future<void>.delayed(Duration.zero);
        }
        await firstFrame?.call();
        expect(
          calls.where((c) => c == 'reportDartBootError').length,
          lessThanOrEqualTo(1),
        );
        if (scenario == 'good') {
          expect(events, ['load', 'assets', 'patched']);
          final timing = logs.singleWhere(
            (line) => line.startsWith('BYTECODE_BOOT_TIMING:'),
          );
          final values = RegExp(
            r'\w+_us=(\d+)',
          ).allMatches(timing).map((m) => int.parse(m.group(1)!)).toList();
          expect(values.length, 5);
          expect(
            values.take(4).fold<int>(0, (sum, value) => sum + value),
            values.last,
          );
          expect(calls.last, 'reportBootSuccess');
        } else if (scenario == 'main' || scenario == 'font') {
          expect(events, isNot(contains('original')));
          expect(calls.last, 'reportDartBootError');
        } else {
          expect(events.where((e) => e == 'original').length, 1);
          expect(calls, isNot(contains('reportBootSuccess')));
        }
      },
    );
  }
}
