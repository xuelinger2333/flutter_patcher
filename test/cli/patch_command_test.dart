import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'package:flutter_patcher/src/cli/core.dart';
import 'package:flutter_patcher/src/cli/keys/bundle.dart';
import 'package:flutter_patcher/src/cli/patch/package.dart';
import 'package:flutter_patcher/src/cli/patch_command.dart';
import 'package:flutter_patcher/src/cli/project.dart';
import 'package:flutter_patcher/src/cli/publish/seal.dart';
import 'package:flutter_patcher/src/patch_file.dart';

import 'host_tools.dart';

Matcher fails(String code) =>
    throwsA(isA<Failure>().having((f) => f.code, 'code', code));

/// What `patch` adds to its draft, the file devices take, and what
/// `patch --withdraw` writes instead: plan/1.1-direct-patching.md §4.5.
void main() {
  late Directory root;
  late String output;
  late ProjectConfig config;
  const name = '12-paid-beta-arm64-v8a.fptc';
  final scope = {
    'application_id': 'com.example.app',
    'channel': 'beta',
    'flavor': 'paid',
    'version_code': '12',
    'abi': 'arm64-v8a',
    'fingerprint': 'cd' * 32,
    'strategy': 'bytecode',
  };
  late PatchDraft draft;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('patch-command-');
    output = p.join(root.path, 'out');
    final module = File(p.join(root.path, 'module.bc'))..writeAsStringSync('x');
    draft = await packPatch(
      kind: 'bytecode',
      code: module.path,
      metadata: {'fingerprint': 'cd' * 32, 'module_id': 3, 'tier': 'lean'},
    );
    await Directory(output).create();
    await draft.write(output);
    config = await ProjectConfig.load(root.path);
  });
  tearDown(() => root.delete(recursive: true));

  Map<String, Object?> report(
    String patchKey, {
    String status = 'patch_created',
  }) => {'status': status, 'scope': scope, 'patch_key': patchKey};

  group('a patch', () {
    test('of an unsigned host is sealed as <output>/<fileName>, numbered '
        'now', () async {
      final before = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final sealed = await sealOutput(output, report('-'), config);
      expect(sealed['file'], name);
      final bytes = File(p.join(output, name)).readAsBytesSync();
      final header = PatchHeader.parse(bytes);
      expect(header.seq, sealed['seq']);
      expect(header.seq, greaterThanOrEqualTo(before));
      expect(header.fingerprint, 'cd' * 32);
      expect(header.withdrawal, isFalse);
      expect(bytes, await sealPatch(draft, seq: header.seq));
      expect(sealed['signed'], isFalse);
      expect(
        DateTime.parse(sealed['sealed_at'] as String).millisecondsSinceEpoch,
        header.seq * 1000,
      );
    });

    test(
      'of a signed host whose key is not here keeps only the draft',
      () async {
        final sealed = await sealOutput(
          output,
          report(KeyBundle.generate().publicKey),
          config,
        );
        expect(sealed['file'], isNull);
        expect(sealed['notice'], contains('keys import'));
        expect(
          Directory(output).listSync().where((e) => e.path.endsWith('.fptc')),
          isEmpty,
        );
        expect(await PatchDraft.read(output), isA<PatchDraft>());
      },
    );

    test('names its file by its full path in the report', () {
      expect(
        located({'output': output, 'file': name})['file'],
        p.join(output, name),
      );
      expect(located({'output': output, 'file': null})['file'], isNull);
    });
  });

  group('a withdrawal', () {
    test(
      'of an unsigned host is a new output holding the withdrawal file',
      () async {
        final dir = p.join(root.path, 'withdrawal');
        final before = DateTime.now().millisecondsSinceEpoch ~/ 1000;
        final result = await writeWithdrawal(
          dir,
          report('-', status: 'withdrawal_created'),
          config,
        );
        expect(result['output'], dir);
        expect(result['file'], p.join(dir, name));
        final bytes = File(p.join(dir, name)).readAsBytesSync();
        final header = PatchHeader.parse(bytes);
        expect(bytes.length, patchHeaderSize);
        expect(header.withdrawal, isTrue);
        expect(header.fingerprint, 'cd' * 32);
        expect(header.seq, result['seq']);
        expect(header.seq, greaterThanOrEqualTo(before));
        expect(
          jsonDecode(
            File(p.join(dir, 'patch.json')).readAsStringSync(),
          )['status'],
          'withdrawal_created',
        );
        expect(
          root.listSync().where((e) => e.path.contains('.pending-')),
          isEmpty,
        );
      },
    );

    test('of a signed host whose key is not here has no file', () async {
      final dir = p.join(root.path, 'withdrawal');
      final result = await writeWithdrawal(
        dir,
        report(KeyBundle.generate().publicKey, status: 'withdrawal_created'),
        config,
      );
      expect(result['file'], isNull);
      expect(File(p.join(dir, 'patch.json')).existsSync(), isTrue);
      expect(File(p.join(dir, name)).existsSync(), isFalse);
    });

    test('compiles nothing, so takes no code options', () async {
      for (final extra in [
        ['--target', 'lib/other.dart'],
        ['--assets', 'assets/a.png'],
      ]) {
        final result = await Process.run(dartVm, [
          p.absolute('bin/flutter_patcher.dart'),
          'patch',
          'android',
          '--withdraw',
          '--project',
          root.path,
          ...extra,
        ]);
        expect(result.exitCode, 2, reason: '$extra');
        expect(result.stderr, contains('USAGE_ERROR'), reason: '$extra');
      }
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('never replaces an output', () async {
      await expectLater(
        writeWithdrawal(
          output,
          report('-', status: 'withdrawal_created'),
          config,
        ),
        fails('PATCH_CONFIG_INVALID'),
      );
    });
  });
}
