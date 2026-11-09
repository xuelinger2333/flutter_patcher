// Some cases run the CLI in subprocesses, each compiling it first.
@Timeout(Duration(minutes: 3))
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'package:flutter_patcher/src/cli/core.dart';
import 'package:flutter_patcher/src/cli/crypto/ed25519.dart';
import 'package:flutter_patcher/src/cli/keys/bundle.dart';
import 'package:flutter_patcher/src/cli/patch/package.dart';
import 'package:flutter_patcher/src/cli/publish/command.dart';
import 'package:flutter_patcher/src/cli/publish/seal.dart';
import 'package:flutter_patcher/src/patch_file.dart';

import 'host_tools.dart';

Matcher fails(String code) =>
    throwsA(isA<Failure>().having((f) => f.code, 'code', code));

/// `publish` and the patch files it writes.
void main() {
  late Directory root;
  late String project, store;
  final fingerprint = 'ab' * 32;
  final scope = {
    'application_id': 'com.example.app',
    'channel': 'production',
    'flavor': 'default',
    'version_code': '7',
    'abi': 'arm64-v8a',
    'fingerprint': fingerprint,
    'strategy': 'bytecode',
  };
  const name = '7-arm64-v8a.fptc';
  var outputs = 0;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('publish-');
    project = p.join(root.path, 'app');
    store = p.join(root.path, 'store');
    await Directory(project).create();
    await File(p.join(project, 'flutter_patcher.yaml'))
        .writeAsString("store: '${Uri.directory(store)}'\n");
  });
  tearDown(() => root.delete(recursive: true));

  /// A finished patch output of the host [scope] trusting [patchKey].
  Future<String> output({String patchKey = '-', String code = 'one'}) async {
    final dir = p.join(
      project,
      '.dart_tool/flutter_patcher/patches',
      '${1000 + outputs++}',
    );
    final work = await Directory(p.join(root.path, 'work-$outputs')).create();
    final module = File(p.join(work.path, 'module.bc'))
      ..writeAsStringSync(code);
    final draft = await packPatch(
      kind: 'bytecode',
      code: module.path,
      metadata: {'fingerprint': fingerprint, 'module_id': 9, 'tier': 'lean'},
    );
    await Directory(dir).create(recursive: true);
    await draft.write(dir);
    await writeObject(p.join(dir, 'patch.json'), {
      'status': 'patch_created',
      'scope': scope,
      'patch_key': patchKey,
    });
    return dir;
  }

  Future<Map<String, dynamic>> publish(List<String> args) =>
      publication(publishOptions().parse(['--project', project, ...args]));

  Uint8List stored() => File(p.join(store, name)).readAsBytesSync();

  test('writes the patch file of an unsigned host, numbered now', () async {
    final dir = await output();
    final before = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final result = await publish(['--patch', dir, '--yes']);
    expect(result['status'], 'published');
    expect(result['action'], 'publish');
    expect(result['file'], name);
    expect(result['signed'], isFalse);
    final bytes = stored();
    final header = PatchHeader.parse(bytes);
    expect(header.seq, result['seq']);
    expect(header.seq, greaterThanOrEqualTo(before));
    expect(header.fingerprint, fingerprint);
    expect(header.withdrawal, isFalse);
    expect(bytes.sublist(82, 146), List.filled(64, 0));
    expect(header.payloadSha256, sha256.convert(bytes.sublist(146)).toString());
  });

  test('previews without --yes when no one can answer', () async {
    final result = await publish(['--patch', await output(), '--seq', '5']);
    expect(result['status'], 'preview');
    expect(result['seq'], 5);
    expect(File(p.join(store, name)).existsSync(), isFalse);
  });

  test('defaults to the latest patch output', () async {
    await output(code: 'old');
    final latest = await output(code: 'new');
    await publish(['--yes', '--seq', '5']);
    expect(stored().sublist(146), (await sealPatchOf(latest, 5)).sublist(146));
  });

  test('the same draft again is already published', () async {
    final dir = await output();
    await publish(['--patch', dir, '--yes', '--seq', '5']);
    final result = await publish(['--patch', dir, '--yes', '--seq', '9']);
    expect(result['status'], 'already_published');
    expect(result['seq'], 5);
    expect(PatchHeader.parse(stored()).seq, 5);
  });

  test('replaces the file only with a newer one', () async {
    await publish(['--patch', await output(code: 'a'), '--yes', '--seq', '5']);
    final newer = await output(code: 'b');
    await expectLater(
      publish(['--patch', newer, '--yes', '--seq', '5']),
      fails('PUBLISH_SEQUENCE_CONFLICT'),
    );
    await expectLater(
      publish(['--patch', newer, '--yes', '--seq', '4']),
      fails('PUBLISH_SEQUENCE_CONFLICT'),
    );
    expect(
      (await publish(['--patch', newer, '--yes', '--seq', '6']))['seq'],
      6,
    );
    expect(PatchHeader.parse(stored()).seq, 6);
  });

  test('refuses a sequence outside 1 to 4294967295', () async {
    for (final seq in ['0', '4294967296', 'x']) {
      await expectLater(
        publish(['--patch', await output(), '--yes', '--seq', seq]),
        fails('PUBLISH_SEQUENCE_CONFLICT'),
      );
    }
  });

  test('withdraws, then rolls back by publishing an old draft again', () async {
    final a = await output(code: 'a');
    await publish(['--patch', a, '--yes', '--seq', '10']);
    final b = await output(code: 'b');
    await publish(['--patch', b, '--yes', '--seq', '20']);
    final withdrawn = await publish([
      '--patch',
      b,
      '--withdraw',
      '--yes',
      '--seq',
      '30',
    ]);
    expect(withdrawn['action'], 'withdraw');
    final header = PatchHeader.parse(stored());
    expect([header.withdrawal, header.seq, stored().length], [true, 30, 146]);
    expect(
      (await publish([
        '--patch',
        b,
        '--withdraw',
        '--yes',
        '--seq',
        '31',
      ]))['status'],
      'already_published',
    );
    // Rolling back to A: its draft again, under a new sequence.
    final back = await publish(['--patch', a, '--yes', '--seq', '40']);
    expect(back['status'], 'published');
    expect(PatchHeader.parse(stored()).seq, 40);
    expect(stored().sublist(146), (await sealPatchOf(a, 40)).sublist(146));
  });

  test('a withdrawal output publishes a withdrawal of its host', () async {
    await publish(['--patch', await output(), '--yes', '--seq', '10']);
    final withdrawal = p.join(
      project,
      '.dart_tool/flutter_patcher/patches',
      '${1000 + outputs++}',
    );
    await writeObject(p.join(withdrawal, 'patch.json'), {
      'status': 'withdrawal_created',
      'scope': scope,
      'patch_key': '-',
    });
    final result = await publish(['--yes', '--seq', '20']);
    expect([result['status'], result['action']], ['published', 'withdraw']);
    final header = PatchHeader.parse(stored());
    expect([header.withdrawal, header.seq], [true, 20]);
  });

  group('a signed host', () {
    late KeyBundle bundle;
    late String keyFile;
    setUp(() {
      bundle = KeyBundle.generate();
      keyFile = p.join(root.path, 'key.json');
      File(keyFile).writeAsStringSync(bundle.encode());
    });

    test('gets files signed by its patch key', () async {
      final dir = await output(patchKey: bundle.publicKey);
      final result = await publish([
        '--patch',
        dir,
        '--yes',
        '--key-file',
        keyFile,
      ]);
      expect(result['signed'], isTrue);
      final bytes = stored();
      expect(
        ed25519Verify(base64Decode(bundle.publicKey), bytes.sublist(82, 146), [
          ...bytes.sublist(0, 82),
          ...bytes.sublist(146),
        ]),
        isTrue,
      );
    });

    test('needs its key', () async {
      final dir = await output(patchKey: bundle.publicKey);
      final other = p.join(root.path, 'other.json');
      File(other).writeAsStringSync(KeyBundle.generate().encode());
      await expectLater(
        publish(['--patch', dir, '--yes', '--key-file', other]),
        fails('KEYS_MISMATCH'),
      );
      expect(File(p.join(store, name)).existsSync(), isFalse);
    });
  });

  test('a store file of that name that is not a patch file is named', () async {
    File(p.join(store, name))
      ..createSync(recursive: true)
      ..writeAsStringSync('not a patch file');
    await expectLater(
      publish(['--patch', await output(), '--yes']),
      throwsA(
        isA<Failure>()
            .having((f) => f.code, 'code', 'PUBLISH_STORE_INVALID')
            .having((f) => f.message, 'message', contains(name)),
      ),
    );
  });

  test('a receipt records the result in a new file', () async {
    final receipt = p.join(root.path, 'receipt.json');
    final result = await publish([
      '--patch',
      await output(),
      '--yes',
      '--seq',
      '5',
      '--receipt',
      receipt,
    ]);
    expect(await readObject(receipt), result);
    await expectLater(
      publish(['--patch', await output(), '--yes', '--receipt', receipt]),
      fails('PUBLISH_CONFIG_INVALID'),
    );
  });

  test('a patch output of flutter_patcher 1.0 is not published here', () async {
    final dir = await output();
    await writeObject(p.join(dir, 'patch.json'), {
      'status': 'patch_created',
      'scope': scope,
      'draft_sha256': 'f' * 64,
    });
    await expectLater(
      publish(['--patch', dir, '--yes']),
      fails('PATCH_BASELINE_INCOMPATIBLE'),
    );
  });

  group('the command line', () {
    Future<ProcessResult> cli(List<String> args, {Map<String, String>? env}) =>
        Process.run(dartVm, [
          p.absolute('bin/flutter_patcher.dart'),
          ...args,
        ], environment: env);

    test('signs with the key in FLUTTER_PATCHER_KEYS', () async {
      final bundle = KeyBundle.generate();
      final dir = await output(patchKey: bundle.publicKey);
      final result = await cli(
        ['publish', '--project', project, '--patch', dir, '--yes'],
        env: {'FLUTTER_PATCHER_KEYS': bundle.encode()},
      );
      expect(result.exitCode, 0, reason: '${result.stderr}');
      final report = jsonDecode(result.stdout as String) as Map;
      expect(
        [report['command'], report['status'], report['signed']],
        ['publish', 'published', true],
      );
    });

    test('removed commands and options are unknown', () async {
      for (final args in [
        ['trust', 'sign'],
        ['publish', '--production', '--request', 'r.json'],
      ]) {
        final result = await cli(args);
        expect(result.exitCode, 2, reason: '$args');
        expect(result.stderr, contains('USAGE_ERROR'), reason: '$args');
      }
    });
  });
}

/// What publish writes for the draft in [dir] at [seq], unsigned.
Future<Uint8List> sealPatchOf(String dir, int seq) async =>
    sealPatch(await PatchDraft.read(dir), seq: seq);
