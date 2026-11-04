import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'package:flutter_patcher/src/cli/core.dart';
import 'package:flutter_patcher/src/cli/crypto/ed25519.dart';
import 'package:flutter_patcher/src/cli/keys/bundle.dart';
import 'package:flutter_patcher/src/cli/keys/keyring.dart';
import 'package:flutter_patcher/src/cli/keys/signer.dart';

import 'host_tools.dart';

Matcher fails(String code) =>
    throwsA(isA<Failure>().having((f) => f.code, 'code', code));

/// A signing command for tests: signs stdin with the seed of
/// FLUTTER_PATCHER_SIGN_ROLE from TEST_SEEDS, or misbehaves on TEST_MODE.
const _signScript = r'''
import 'dart:convert';
import 'dart:io';
import 'package:flutter_patcher/src/cli/crypto/ed25519.dart';

Future<void> main() async {
  final env = Platform.environment;
  final record = env['TEST_RECORD'];
  if (record != null) {
    File(record).writeAsStringSync(jsonEncode({
      'role': env['FLUTTER_PATCHER_SIGN_ROLE'],
      'public': env['FLUTTER_PATCHER_SIGN_PUBLIC_KEY'],
      'bundle': env['FLUTTER_PATCHER_KEYS'],
    }));
  }
  switch (env['TEST_MODE']) {
    case 'fail':
      stderr.write('access denied by kms');
      exit(3);
    case 'garbage':
      stdout.write('not a signature');
      return;
    case 'sleep':
      await Future<void>.delayed(const Duration(seconds: 20));
  }
  final message = await stdin.fold<List<int>>([], (a, b) => a..addAll(b));
  final seeds = jsonDecode(env['TEST_SEEDS']!) as Map;
  final seed = base64Decode(seeds[env['FLUTTER_PATCHER_SIGN_ROLE']] as String);
  stdout.write(base64Encode(ed25519Sign(seed, message)));
}
''';

void main() {
  late Directory temp;
  late String store;
  setUp(() {
    temp = Directory.systemTemp.createTempSync('keyring-');
    store = p.join(temp.path, 'store');
  });
  tearDown(() => temp.deleteSync(recursive: true));

  final message = utf8.encode('flutter_patcher test message');
  bool verifies(String public, List<int> signature) =>
      ed25519Verify(base64Decode(public), signature, message);

  group('KeyBundle', () {
    test('round-trips as JSON and as base64 JSON', () {
      final bundle = KeyBundle.generate();
      final text = bundle.encode();
      expect(KeyBundle.decode(text).encode(), text);
      expect(KeyBundle.decode(base64Encode(utf8.encode(text))).encode(), text);
      expect(KeyBundle.decode('\n$text\n').encode(), text);
      expect(bundle.anchors.root, bundle.publicKey(KeyRole.root));
      expect(bundle.matches(bundle.anchors), true);
    });

    test('encodes canonically, roles in a fixed order', () {
      final seed = Uint8List(32);
      final a = KeyBundle({KeyRole.patch: seed, KeyRole.root: seed});
      final b = KeyBundle({KeyRole.root: seed, KeyRole.patch: seed});
      expect(a.encode(), b.encode());
      expect(a.encode(), startsWith('{"format":"flutter_patcher.keys.v1"'));
    });

    test('rejects anything else', () {
      final seed = base64Encode(Uint8List(32));
      for (final text in [
        '',
        'not base64 or json',
        '[]',
        '{"format":"flutter_patcher.keys.v2","keys":{"root":"$seed"}}',
        '{"format":"flutter_patcher.keys.v1","keys":{}}',
        '{"format":"flutter_patcher.keys.v1","keys":{"admin":"$seed"}}',
        '{"format":"flutter_patcher.keys.v1","keys":{"root":"AAAA"}}',
        '{"format":"flutter_patcher.keys.v1","keys":{"root":"$seed"},"x":1}',
        '{"format":"flutter_patcher.keys.v1","keys":{"root":"$seed","root":"$seed"}}',
      ]) {
        expect(
          () => KeyBundle.decode(text),
          fails('KEYS_BUNDLE_INVALID'),
          reason: text,
        );
      }
    });

    test('a partial bundle has no anchors', () {
      final partial = KeyBundle.generate().without(KeyRole.root);
      expect(() => partial.anchors, fails('KEYS_BUNDLE_INVALID'));
    });

    test('reads the pre-1.0 key directory', () async {
      final bundle = KeyBundle.generate();
      for (final role in KeyRole.values) {
        final dir = Directory(p.join(temp.path, 'legacy', role.name))
          ..createSync(recursive: true);
        File(p.join(dir.path, 'private-key.base64'))
            .writeAsStringSync('${base64Encode(bundle.seeds[role]!)}\n');
      }
      final read = await KeyBundle.readDirectory(p.join(temp.path, 'legacy'));
      expect(read.encode(), bundle.encode());
      await expectLater(
        KeyBundle.readDirectory(p.join(temp.path, 'none')),
        fails('KEYS_BUNDLE_INVALID'),
      );
    });
  });

  group('TrustAnchors', () {
    test('come from a host policy', () {
      final anchors = KeyBundle.generate().anchors;
      final policy = TrustAnchors.ofPolicy({
        'root_key': anchors.root,
        'fptc_key': anchors.patch,
        'keys': 'backup:${anchors.root},release:${anchors.publisher}',
      });
      expect(policy.publisher, anchors.publisher);
      expect(policy.id, anchors.id);
      expect(anchors.id, hasLength(16));
    });

    test('reject keys that are not Ed25519 public keys', () {
      final key = KeyBundle.generate().anchors.root;
      expect(
        () => TrustAnchors(root: key, publisher: 'x', patch: key),
        fails('KEYS_NOT_CONFIGURED'),
      );
    });
  });

  group('key store', () {
    test('saves privately, loads, and is idempotent', () async {
      final bundle = KeyBundle.generate();
      final path = await saveKeyStore(bundle, root: store);
      expect(p.basename(p.dirname(path)), bundle.anchors.id);
      expect(
        (await loadKeyStore(bundle.anchors, root: store))!.encode(),
        bundle.encode(),
      );
      expect(await saveKeyStore(bundle, root: store), path);
      if (Platform.isWindows) {
        final acl =
            Process.runSync('icacls', [p.dirname(path)]).stdout as String;
        expect(acl, contains(Platform.environment['USERNAME']!));
        expect(acl, isNot(contains('BUILTIN\\Users')));
        expect(acl, isNot(contains('Everyone')));
      } else {
        expect(File(path).statSync().mode & 0x1ff, 0x180); // 0600
        expect(Directory(p.dirname(path)).statSync().mode & 0x1ff, 0x1c0);
      }
      expect(Directory(p.dirname(path)).listSync(), hasLength(1));
    });

    test('is completed, never overwritten with other keys', () async {
      final bundle = KeyBundle.generate();
      final partial = bundle.without(KeyRole.patch);
      await saveKeyStore(partial, root: store);
      await saveKeyStore(bundle, root: store);
      expect(
        (await loadKeyStore(bundle.anchors, root: store))!.encode(),
        bundle.encode(),
      );
      // A partial import keeps what the store already has.
      await saveKeyStore(partial, root: store);
      expect(
        (await loadKeyStore(bundle.anchors, root: store))!.encode(),
        bundle.encode(),
      );

      final other = KeyBundle({
        ...bundle.seeds,
        KeyRole.patch: KeyBundle.generate().seeds[KeyRole.patch]!,
      });
      await expectLater(
        saveKeyStore(other, root: store),
        fails('KEYS_MISMATCH'),
      );
      await expectLater(
        saveKeyStore(other, root: store, replace: true),
        fails('KEYS_MISMATCH'),
      );
    });

    test('replace gives it a new publisher key only', () async {
      final bundle = KeyBundle.generate();
      await saveKeyStore(bundle, root: store);
      final rotated = KeyBundle({
        ...bundle.seeds,
        KeyRole.publisher: KeyBundle.generate().seeds[KeyRole.publisher]!,
      });
      await expectLater(
        saveKeyStore(rotated, root: store),
        fails('KEYS_MISMATCH'),
      );
      await saveKeyStore(rotated, root: store, replace: true);
      expect(
        (await loadKeyStore(rotated.anchors, root: store))!.encode(),
        rotated.encode(),
      );
      // The old anchors no longer match what is stored.
      await expectLater(
        loadKeyStore(bundle.anchors, root: store),
        fails('KEYS_MISMATCH'),
      );
    });

    test('needs the root key, which names the project', () async {
      await expectLater(
        saveKeyStore(KeyBundle.generate().without(KeyRole.root), root: store),
        fails('KEYS_BUNDLE_INVALID'),
      );
    });
  });

  group('Keyring', () {
    late KeyBundle bundle;
    setUp(() => bundle = KeyBundle.generate());

    Keyring keyring({
      String? keyFile,
      String? command,
      Map<String, String> env = const {},
    }) => Keyring(
      bundle.anchors,
      keyFile: keyFile,
      command: command,
      keyStore: store,
      environment: {...Platform.environment, ...env}
        ..remove(Keyring.environmentVariable)
        ..addAll(env),
    );

    test('finds nothing without a source and names what it tried', () async {
      await expectLater(
        keyring().signer(KeyRole.patch),
        throwsA(
          isA<Failure>()
              .having((f) => f.code, 'code', 'KEYS_NOT_FOUND')
              .having((f) => f.message, 'message', contains('the key store')),
        ),
      );
    });

    test('signs from the key store', () async {
      await saveKeyStore(bundle, root: store);
      for (final role in KeyRole.values) {
        final signer = await keyring().signer(role);
        expect(signer.source, 'key store');
        expect(
          verifies(bundle.anchors.of(role), await signer.sign(message)),
          true,
        );
      }
    });

    test('prefers --key-file, then the environment, then the store', () async {
      await saveKeyStore(bundle, root: store);
      final file = File(p.join(temp.path, 'keys.json'))
        ..writeAsStringSync(bundle.without(KeyRole.root).encode());
      final env = {
        Keyring.environmentVariable: base64Encode(
          utf8.encode(bundle.without(KeyRole.patch).encode()),
        ),
      };
      final ring = keyring(keyFile: file.path, env: env);
      expect((await ring.signer(KeyRole.patch)).source, '--key-file');
      expect((await ring.signer(KeyRole.publisher)).source, '--key-file');
      expect(
        (await ring.signer(KeyRole.root)).source,
        Keyring.environmentVariable,
      );
      expect(
        (await keyring(env: env).signer(KeyRole.patch)).source,
        'key store',
      );
      expect(await ring.describe(), {
        KeyRole.root: Keyring.environmentVariable,
        KeyRole.publisher: '--key-file',
        KeyRole.patch: '--key-file',
      });
    });

    test(
      'a source with another key fails instead of falling through',
      () async {
        await saveKeyStore(bundle, root: store);
        final stranger = KeyBundle.generate();
        final env = {Keyring.environmentVariable: stranger.encode()};
        await expectLater(
          keyring(env: env).signer(KeyRole.publisher),
          fails('KEYS_MISMATCH'),
        );
        expect(
          (await keyring(env: env).describe())[KeyRole.publisher],
          contains('other key'),
        );
      },
    );

    test('a missing --key-file is an error', () async {
      await expectLater(
        keyring(keyFile: p.join(temp.path, 'absent.json'))
            .signer(KeyRole.patch),
        fails('KEYS_NOT_FOUND'),
      );
    });

    test('a bad environment bundle is an error', () async {
      await expectLater(
        keyring(env: {Keyring.environmentVariable: 'garbage'})
            .signer(KeyRole.patch),
        fails('KEYS_BUNDLE_INVALID'),
      );
    });

    group('signing.command', () {
      late String command;
      late Map<String, String> seeds;
      setUp(() {
        final script = File(p.join(temp.path, 'sign.dart'))
          ..writeAsStringSync(_signScript);
        final packages = p.absolute('.dart_tool', 'package_config.json');
        command = '"$dartVm" --packages="$packages" "${script.path}"';
        seeds = {
          for (final role in KeyRole.values)
            role.name: base64Encode(bundle.seeds[role]!),
        };
      });

      test('signs every role without the key bundle reaching it', () async {
        final record = p.join(temp.path, 'record.json');
        final ring = keyring(
          command: command,
          env: {
            'TEST_SEEDS': jsonEncode(seeds),
            'TEST_RECORD': record,
            Keyring.environmentVariable: KeyBundle.generate()
                .without(KeyRole.patch)
                .encode(),
          },
        );
        final signer = await ring.signer(KeyRole.patch);
        expect(signer.source, 'signing.command');
        expect(
          verifies(bundle.anchors.patch, await signer.sign(message)),
          true,
        );
        final seen = jsonDecode(File(record).readAsStringSync()) as Map;
        expect(seen['role'], 'patch');
        expect(seen['public'], bundle.anchors.patch);
        expect(seen['bundle'], isNull);
      }, timeout: const Timeout(Duration(minutes: 2)));

      test('a signature for another key fails closed', () async {
        final wrong = KeyBundle.generate();
        final ring = keyring(
          command: command,
          env: {
            'TEST_SEEDS': jsonEncode({
              for (final role in KeyRole.values)
                role.name: base64Encode(wrong.seeds[role]!),
            }),
          },
        );
        final signer = await ring.signer(KeyRole.publisher);
        await expectLater(signer.sign(message), fails('SIGNER_COMMAND_FAILED'));
      }, timeout: const Timeout(Duration(minutes: 2)));

      test('reports a failing command with its output', () async {
        final signer = await keyring(
          command: command,
          env: {'TEST_MODE': 'fail'},
        ).signer(KeyRole.patch);
        await expectLater(
          signer.sign(message),
          throwsA(
            isA<Failure>()
                .having((f) => f.code, 'code', 'SIGNER_COMMAND_FAILED')
                .having((f) => f.message, 'message', contains('kms')),
          ),
        );
      }, timeout: const Timeout(Duration(minutes: 2)));

      test('rejects output that is not a signature', () async {
        final signer = await keyring(
          command: command,
          env: {'TEST_MODE': 'garbage'},
        ).signer(KeyRole.patch);
        await expectLater(signer.sign(message), fails('SIGNER_COMMAND_FAILED'));
      }, timeout: const Timeout(Duration(minutes: 2)));

      test('gives up after its timeout', () async {
        final signer = CommandSigner(
          KeyRole.patch,
          command,
          bundle.anchors.patch,
          environment: {...Platform.environment, 'TEST_MODE': 'sleep'},
          timeout: const Duration(seconds: 5),
        );
        await expectLater(signer.sign(message), fails('SIGNER_COMMAND_FAILED'));
      }, timeout: const Timeout(Duration(minutes: 2)));
    });
  });
}
