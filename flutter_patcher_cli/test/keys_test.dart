import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:flutter_patcher_cli/src/core.dart';
import 'package:flutter_patcher_cli/src/sdk/host.dart';
import 'package:flutter_patcher_cli/src/build/bootstrap.dart';
import 'package:flutter_patcher_cli/src/patch/package.dart';

void main() {
  Future<ProcessResult> cli(List<String> args,
          {Map<String, String>? environment}) =>
      Process.run(Platform.resolvedExecutable,
          ['bin/flutter_patcher.dart', 'keys', ...args],
          environment: environment);
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
        final privateFile = File(report['private_key'] as String);
        final secret = privateFile.readAsStringSync().trim();
        final public =
            File(report['public_key'] as String).readAsStringSync().trim();
        expect(base64Decode(secret).length, 32);
        expect(base64Decode(public).length, 32);
        expect(result.stdout, isNot(contains(secret)));
        expect(result.stderr, isNot(contains(secret)));
        if (Platform.isWindows) {
          // Inheritance removed and only the current user granted.
          final acl = Process.runSync('icacls', [out]).stdout as String;
          expect(acl, contains(Platform.environment['USERNAME']!));
          expect(acl, isNot(contains('BUILTIN\\Users')));
          expect(acl, isNot(contains('Everyone')));
        } else {
          expect(Directory(out).statSync().mode & 0x1ff, 0x1c0); // 0700
          expect(privateFile.statSync().mode & 0x1ff, 0x180); // 0600
        }
        expect(File(p.join(out, '.gitignore')).readAsStringSync(),
            contains('private-key.base64'));
        expect(bootstrapSource('app', 'main.dart', 'ab' * 32, public),
            contains(public));
        publicKeys.add(public);
      }
      expect(publicKeys.toSet().length, 2);
    });
    test('generated keys sign and pack a patch', () async {
      final out = p.join(root.path, 'keys');
      final result = await cli(['init', '--out', out]);
      expect(result.exitCode, 0, reason: '${result.stderr}');
      final report = jsonDecode(result.stdout as String) as Map;
      final secret =
          File(report['private_key'] as String).readAsStringSync().trim();
      final public =
          File(report['public_key'] as String).readAsStringSync().trim();
      final work = Directory(p.join(root.path, 'work'))..createSync();
      final commands = Commands(root.path);
      final key =
          await signingKey(secret, work.path, commands, expectedPublic: public);
      final module = File(p.join(work.path, 'module.bc'))
        ..writeAsStringSync('synthetic signing contract only');
      final packed = await packPatch(
          module: module.path,
          work: work.path,
          metadata: {
            'format_version': 1,
            'fingerprint': 'ab' * 32,
            'patch_seq': 1,
            'tier': 'lean'
          },
          key: key,
          commands: commands);
      expect(File(packed['file'] as String).lengthSync(), greaterThan(146));
    },
        tags: 'openssl',
        skip: Platform.isLinux
            ? false
            : 'OpenSSL via /dev/stdin is POSIX-only until WP-2.6 phase B');
    test('existing keys remain byte-for-byte unchanged on retry', () async {
      final out = p.join(root.path, 'keys');
      expect((await cli(['init', '--out', out])).exitCode, 0);
      final before = File(p.join(out, 'private-key.base64')).readAsBytesSync();
      final retry = await cli(['init', '--out', out]);
      expect(retry.exitCode, 2);
      expect(retry.stderr, contains('KEYS_OUTPUT_EXISTS'));
      expect(File(p.join(out, 'private-key.base64')).readAsBytesSync(), before);
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
          base64Decode(File(p.join(out, 'private-key.base64'))
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
    test('missing crypto tool fails before creating the output', () async {
      final out = p.join(root.path, 'keys');
      final result =
          await cli(['init', '--out', out], environment: {'PATH': ''});
      expect(result.exitCode, 2);
      expect(result.stderr, contains('KEYS_CRYPTO_UNAVAILABLE'));
      expect(Directory(out).existsSync(), false);
    });
    test('default location uses HOME and never prints private material',
        () async {
      final result = await cli(['init'], environment: {'HOME': root.path});
      expect(result.exitCode, 0, reason: '${result.stderr}');
      final file =
          File(p.join(root.path, '.flutter_patcher/keys/private-key.base64'));
      expect(file.existsSync(), true);
      expect(result.stdout, isNot(contains(file.readAsStringSync().trim())));
    });
  });
}
