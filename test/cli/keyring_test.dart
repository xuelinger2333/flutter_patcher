import 'dart:convert';
import 'dart:io';

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

/// A signing command for tests: signs stdin with TEST_SEED, or misbehaves
/// on TEST_MODE, and records what it was given in TEST_RECORD.
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
  stdout.write(base64Encode(ed25519Sign(base64Decode(env['TEST_SEED']!), message)));
}
''';

/// The patch key, the one key: plan/1.1-direct-patching.md §4.5.
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

  group('a key bundle', () {
    test('round-trips as JSON and as base64 JSON', () {
      final bundle = KeyBundle.generate();
      final text = bundle.encode();
      expect(jsonDecode(text), {
        'format': 'flutter_patcher.keys.v1',
        'keys': {'patch': base64Encode(bundle.seed)},
      });
      expect(KeyBundle.decode(text).publicKey, bundle.publicKey);
      expect(
        KeyBundle.decode(base64Encode(utf8.encode(text))).publicKey,
        bundle.publicKey,
      );
    });

    test('from flutter_patcher 1.0 yields its patch key', () {
      final patch = base64Encode(ed25519GenerateSeed());
      final legacy = jsonEncode({
        'format': 'flutter_patcher.keys.v1',
        'keys': {
          'root': base64Encode(ed25519GenerateSeed()),
          'publisher': base64Encode(ed25519GenerateSeed()),
          'patch': patch,
        },
      });
      expect(base64Encode(KeyBundle.decode(legacy).seed), patch);
    });

    test('without a patch key, or anything else, is invalid', () {
      for (final text in [
        jsonEncode({
          'format': 'flutter_patcher.keys.v1',
          'keys': {'publisher': base64Encode(ed25519GenerateSeed())},
        }),
        jsonEncode({
          'format': 'flutter_patcher.keys.v1',
          'keys': {'patch': base64Encode(ed25519GenerateSeed()), 'other': 'x'},
        }),
        jsonEncode({
          'format': 'other',
          'keys': {'patch': base64Encode(ed25519GenerateSeed())},
        }),
        '{"format":"flutter_patcher.keys.v1","keys":{"patch":"AAAA"}}',
        'garbage',
      ]) {
        expect(() => KeyBundle.decode(text), fails('KEYS_BUNDLE_INVALID'));
      }
    });

    test('reads the pre-1.0 key directory', () async {
      final seed = base64Encode(ed25519GenerateSeed());
      File(p.join(temp.path, 'old', 'patch', 'private-key.base64'))
        ..createSync(recursive: true)
        ..writeAsStringSync('$seed\n');
      expect(
        base64Encode(
          (await KeyBundle.readDirectory(p.join(temp.path, 'old'))).seed,
        ),
        seed,
      );
    });
  });

  group('the key store', () {
    test('saves privately, finds by public key, and is idempotent', () async {
      final bundle = KeyBundle.generate();
      final path = await saveKeyStore(bundle, root: store);
      expect(p.isWithin(store, path), isTrue);
      expect(await saveKeyStore(bundle, root: store), path);
      expect(
        (await loadKeyStore(bundle.publicKey, root: store))!.publicKey,
        bundle.publicKey,
      );
      expect(
        await loadKeyStore(KeyBundle.generate().publicKey, root: store),
        isNull,
      );
      if (!Platform.isWindows) {
        expect(
          (await Process.run('stat', [
            '-c',
            '%a',
            path,
          ])).stdout.toString().trim(),
          anyOf('600', isEmpty),
        );
      }
    });

    test('finds the patch key in a flutter_patcher 1.0 directory', () async {
      final patch = ed25519GenerateSeed();
      final legacy = File(p.join(store, '0123456789abcdef', 'keys.json'))
        ..createSync(recursive: true)
        ..writeAsStringSync(
          jsonEncode({
            'format': 'flutter_patcher.keys.v1',
            'keys': {
              'root': base64Encode(ed25519GenerateSeed()),
              'patch': base64Encode(patch),
            },
          }),
        );
      final bundle = KeyBundle(patch);
      expect(
        (await loadKeyStore(bundle.publicKey, root: store))!.publicKey,
        bundle.publicKey,
      );
      // Saving it again keeps the directory it is in.
      expect(await saveKeyStore(bundle, root: store), legacy.path);
    });

    test('passes over 1.0 bundles without a patch key', () async {
      File(p.join(store, 'aaaaaaaaaaaaaaaa', 'keys.json'))
        ..createSync(recursive: true)
        ..writeAsStringSync(
          jsonEncode({
            'format': 'flutter_patcher.keys.v1',
            'keys': {'publisher': base64Encode(ed25519GenerateSeed())},
          }),
        );
      expect(
        await loadKeyStore(KeyBundle.generate().publicKey, root: store),
        isNull,
      );
    });

    test('names a broken bundle it meets', () async {
      final broken = File(p.join(store, 'bbbbbbbbbbbbbbbb', 'keys.json'))
        ..createSync(recursive: true)
        ..writeAsStringSync('garbage');
      await expectLater(
        loadKeyStore(KeyBundle.generate().publicKey, root: store),
        throwsA(
          isA<Failure>()
              .having((f) => f.code, 'code', 'KEYS_BUNDLE_INVALID')
              .having((f) => f.message, 'message', contains(broken.path)),
        ),
      );
    });
  });

  group('the keyring', () {
    late KeyBundle bundle;
    setUp(() => bundle = KeyBundle.generate());
    Keyring keyring({
      String? keyFile,
      String? command,
      Map<String, String>? env,
    }) => Keyring(
      bundle.publicKey,
      keyFile: keyFile,
      command: command,
      keyStore: store,
      environment: env ?? const {},
    );

    test('finds nothing without a source and names what it tried', () async {
      await expectLater(
        keyring().signer(),
        throwsA(
          isA<Failure>()
              .having((f) => f.code, 'code', 'KEYS_NOT_FOUND')
              .having((f) => f.message, 'message', contains('the key store')),
        ),
      );
      expect(await keyring().describe(), 'none');
    });

    test('signs from the key store', () async {
      await saveKeyStore(bundle, root: store);
      final signer = await keyring().signer();
      expect(signer.source, 'key store');
      expect(verifies(bundle.publicKey, await signer.sign(message)), isTrue);
    });

    test('prefers --key-file, then the environment, then the store', () async {
      await saveKeyStore(bundle, root: store);
      final file = p.join(temp.path, 'bundle.json');
      File(file).writeAsStringSync(bundle.encode());
      final env = {Keyring.environmentVariable: bundle.encode()};
      expect(
        (await keyring(keyFile: file, env: env).signer()).source,
        '--key-file',
      );
      expect(
        (await keyring(env: env).signer()).source,
        Keyring.environmentVariable,
      );
      expect(await keyring(env: env).describe(), Keyring.environmentVariable);
    });

    test('another key is a mismatch, never skipped', () async {
      final env = {Keyring.environmentVariable: KeyBundle.generate().encode()};
      await saveKeyStore(bundle, root: store);
      await expectLater(keyring(env: env).signer(), fails('KEYS_MISMATCH'));
      expect(await keyring(env: env).describe(), contains('other key'));
    });

    test('a missing --key-file is an error', () async {
      await expectLater(
        keyring(keyFile: p.join(temp.path, 'none.json')).signer(),
        fails('KEYS_NOT_FOUND'),
      );
    });

    group('signing.command', () {
      late String command;
      setUp(() {
        final script = File(p.join(temp.path, 'sign.dart'))
          ..writeAsStringSync(_signScript);
        final packages = p.absolute('.dart_tool', 'package_config.json');
        command = '"$dartVm" --packages="$packages" "${script.path}"';
      });

      test('signs as patch without the key bundle reaching it', () async {
        final record = p.join(temp.path, 'record.json');
        final signer = await keyring(
          command: command,
          env: {
            'TEST_SEED': base64Encode(bundle.seed),
            'TEST_RECORD': record,
            ...Platform.environment,
          },
        ).signer();
        expect(signer.source, 'signing.command');
        expect(verifies(bundle.publicKey, await signer.sign(message)), isTrue);
        final seen = jsonDecode(File(record).readAsStringSync()) as Map;
        expect(seen['role'], 'patch');
        expect(seen['public'], bundle.publicKey);
        expect(seen['bundle'], isNull);
      }, timeout: const Timeout(Duration(minutes: 2)));

      test('a signature for another key fails closed', () async {
        final signer = await keyring(
          command: command,
          env: {
            ...Platform.environment,
            'TEST_SEED': base64Encode(ed25519GenerateSeed()),
          },
        ).signer();
        await expectLater(signer.sign(message), fails('SIGNER_COMMAND_FAILED'));
      }, timeout: const Timeout(Duration(minutes: 2)));

      test('reports a failing command with its output', () async {
        final signer = await keyring(
          command: command,
          env: {...Platform.environment, 'TEST_MODE': 'fail'},
        ).signer();
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
          env: {...Platform.environment, 'TEST_MODE': 'garbage'},
        ).signer();
        await expectLater(signer.sign(message), fails('SIGNER_COMMAND_FAILED'));
      }, timeout: const Timeout(Duration(minutes: 2)));

      test('gives up after its timeout', () async {
        final signer = CommandSigner(
          command,
          bundle.publicKey,
          environment: {...Platform.environment, 'TEST_MODE': 'sleep'},
          timeout: const Duration(seconds: 5),
        );
        await expectLater(signer.sign(message), fails('SIGNER_COMMAND_FAILED'));
      }, timeout: const Timeout(Duration(minutes: 2)));
    });
  });
}
