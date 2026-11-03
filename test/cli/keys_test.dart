import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'host_tools.dart';
import 'package:flutter_patcher/src/cli/core.dart';
import 'package:flutter_patcher/src/cli/sdk/host.dart';
import 'package:flutter_patcher/src/cli/build/bootstrap.dart';
import 'package:flutter_patcher/src/cli/patch/package.dart';

void main() {
  Future<ProcessResult> cli(List<String> args,
          {Map<String, String>? environment, String? workingDirectory}) =>
      Process.run(dartVm,
          [p.absolute('bin/flutter_patcher.dart'), 'keys', ...args],
          environment: environment, workingDirectory: workingDirectory);
  Map role(ProcessResult result, String name) =>
      ((jsonDecode(result.stdout as String) as Map)['keys'] as Map)[name]
          as Map;
  test('keys help and invalid usage require no SDK or output directory',
      () async {
    expect((await cli(['init', '--help'])).exitCode, 0);
    for (final args in [
      <String>[],
      ['rotate'],
      ['init', 'extra'],
      ['init', '--force']
    ]) {
      final result = await cli(args);
      expect(result.exitCode, 2);
      expect(result.stderr, contains('USAGE_ERROR'));
    }
  });
  if (!HostIdentity.verified.contains(HostIdentity.current().key)) {
    test('unsupported host fails without creating keys', () async {
      final root = Directory.systemTemp.createTempSync('keys-host-');
      addTearDown(() => root.deleteSync(recursive: true));
      final out = p.join(root.path, 'keys');
      final result = await cli(['init', '--out', out]);
      expect(result.exitCode, 2);
      expect(result.stderr, contains('HOST_UNSUPPORTED'));
      expect(Directory(out).existsSync(), false);
    });
    return;
  }
  group('key initialization on a verified host', () {
    late Directory root;
    setUp(() {
      root = Directory.systemTemp.createTempSync('keys-init-');
    });
    tearDown(() => root.deleteSync(recursive: true));
    test('generates protected, distinct pairs compatible with build and patch',
        () async {
      final publicKeys = <String>[];
      for (var i = 0; i < 2; i++) {
        final out = p.join(root.path, 'keys-$i');
        final result = await cli(['init', '--out', out]);
        expect(result.exitCode, 0, reason: '${result.stderr}');
        final report = jsonDecode(result.stdout as String) as Map;
        expect(report['status'], 'keys_created');
        expect((report['keys'] as Map).keys, ['root', 'publisher', 'patch']);
        for (final name in ['root', 'publisher', 'patch']) {
          final privateFile = File(role(result, name)['private_key'] as String);
          final secret = privateFile.readAsStringSync().trim();
          final public = File(role(result, name)['public_key'] as String)
              .readAsStringSync()
              .trim();
          expect(base64Decode(secret).length, 32);
          expect(base64Decode(public).length, 32);
          expect(result.stdout, isNot(contains(secret)));
          expect(result.stderr, isNot(contains(secret)));
          if (!Platform.isWindows) {
            expect(privateFile.statSync().mode & 0x1ff, 0x180); // 0600
          }
          expect(bootstrapSource('app', 'main.dart', 'ab' * 32, public),
              contains(public));
          publicKeys.add(public);
        }
        if (Platform.isWindows) {
          // Inheritance removed and only the current user granted.
          final acl = Process.runSync('icacls', [out]).stdout as String;
          expect(acl, contains(Platform.environment['USERNAME']!));
          expect(acl, isNot(contains('BUILTIN\\Users')));
          expect(acl, isNot(contains('Everyone')));
        } else {
          expect(Directory(out).statSync().mode & 0x1ff, 0x1c0); // 0700
        }
        expect(File(p.join(out, '.gitignore')).readAsStringSync(),
            contains('*/private-key.base64'));
      }
      expect(publicKeys.toSet().length, 6);
    });
    test('generated keys sign and pack a patch', () async {
      final out = p.join(root.path, 'keys');
      final result = await cli(['init', '--out', out]);
      expect(result.exitCode, 0, reason: '${result.stderr}');
      // Use the files exactly as written, trailing newline included.
      final patch = role(result, 'patch');
      final secret = File(patch['private_key'] as String).readAsStringSync();
      final public = File(patch['public_key'] as String).readAsStringSync();
      final work = Directory(p.join(root.path, 'work'))..createSync();
      final commands = Commands(root.path);
      final key = signingKey(secret, expectedPublic: public);
      final module = File(p.join(work.path, 'module.bc'))
        ..writeAsStringSync('synthetic signing contract only');
      final packed = await packPatch(
          kind: 'bytecode',
          code: module.path,
          work: work.path,
          metadata: {
            'fingerprint': 'ab' * 32,
            'patch_seq': 1,
            'tier': 'lean'
          },
          key: key,
          commands: commands);
      expect(File(packed['file'] as String).lengthSync(), greaterThan(146));
    });
    test('existing keys remain byte-for-byte unchanged on retry', () async {
      final out = p.join(root.path, 'keys');
      expect((await cli(['init', '--out', out])).exitCode, 0);
      final before = File(p.join(out, 'root', 'private-key.base64')).readAsBytesSync();
      final retry = await cli(['init', '--out', out]);
      expect(retry.exitCode, 2);
      expect(retry.stderr, contains('KEYS_OUTPUT_EXISTS'));
      expect(File(p.join(out, 'root', 'private-key.base64')).readAsBytesSync(), before);
    });
    test('concurrent initializers have exactly one winner', () async {
      final out = p.join(root.path, 'keys');
      final results = await Future.wait([
        cli(['init', '--out', out]),
        cli(['init', '--out', out])
      ]);
      expect(results.where((r) => r.exitCode == 0).length, 1);
      expect(results.where((r) => r.exitCode == 2).length, 1);
      expect(
          base64Decode(File(p.join(out, 'root', 'private-key.base64'))
                  .readAsStringSync()
                  .trim())
              .length,
          32);
    });
    test('rejects symlink ancestors without writing into their target',
        () async {
      final actual = Directory(p.join(root.path, 'actual'))..createSync();
      final link = Link(p.join(root.path, 'link'))..createSync(actual.path);
      expect((await cli(['init', '--out', p.join(link.path, 'keys')])).exitCode,
          2);
      expect(actual.listSync(), isEmpty);
    }, tags: 'symlink');
    test('key generation needs no external tool', () async {
      final out = p.join(root.path, 'keys');
      final result =
          await cli(['init', '--out', out], environment: {'PATH': ''});
      expect(result.exitCode, 0, reason: '${result.stderr}');
      expect(File(p.join(out, 'patch', 'public-key.base64')).existsSync(), true);
    });
    test('by default the project gets its keys and a settings template',
        () async {
      final result = await cli(['init'], workingDirectory: root.path);
      expect(result.exitCode, 0, reason: '${result.stderr}');
      final file = File(p.join(
          root.path, 'flutter_patcher_keys/publisher/private-key.base64'));
      expect(file.existsSync(), true);
      expect(result.stdout, isNot(contains(file.readAsStringSync().trim())));
      expect(File(p.join(root.path, 'flutter_patcher.yaml')).readAsStringSync(),
          contains('public_url'));
    });
  });
}
