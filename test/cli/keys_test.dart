// Runs the CLI in subprocesses, each compiling it first: slow under load.
@Timeout(Duration(minutes: 3))
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'host_tools.dart';

import 'package:flutter_patcher/src/cli/crypto/ed25519.dart';
import 'package:flutter_patcher/src/cli/keys/bundle.dart';
import 'package:flutter_patcher/src/cli/sdk/host.dart';

void main() {
  late Directory root;
  setUp(() => root = Directory.systemTemp.createTempSync('keys-'));
  tearDown(() => root.deleteSync(recursive: true));

  /// A machine: its own home, so its own key store.
  Map<String, String> machine(String name) {
    final home = p.join(root.path, name);
    Directory(home).createSync(recursive: true);
    return {'HOME': home, 'USERPROFILE': home};
  }

  Future<ProcessResult> cli(
    List<String> args, {
    required Map<String, String> environment,
    String? project,
  }) => Process.run(dartVm, [
    p.absolute('bin/flutter_patcher.dart'),
    'keys',
    ...args,
    if (project != null) ...['--project', project],
  ], environment: environment);

  Map report(ProcessResult result) {
    expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
    return jsonDecode(result.stdout as String) as Map;
  }

  String project(String name) =>
      (Directory(p.join(root.path, name))..createSync()).path;

  String yaml(String project) =>
      File(p.join(project, 'flutter_patcher.yaml')).readAsStringSync();

  test('help and invalid usage', () async {
    final env = machine('a');
    expect((await cli(['init', '--help'], environment: env)).exitCode, 0);
    for (final args in [
      <String>[],
      ['rotate'],
      ['import', 'x', '--rotate'],
      ['init', '--out', 'x', '--role', 'publisher'],
      ['init', 'extra'],
      ['init', '--force'],
      ['import'],
      ['export'],
      ['export', '--base64', '--out', 'x'],
      ['init', '--role', 'patch'],
      ['init', '--out', 'x', '--role', 'patch'],
      ['export', '--base64', '--without-root'],
    ]) {
      final result = await cli(args, environment: env);
      expect(result.exitCode, 2, reason: '$args');
      expect(result.stderr, contains('USAGE_ERROR'), reason: '$args');
    }
  });

  if (!HostIdentity.verified.contains(HostIdentity.current().key)) {
    test('unsupported host fails without creating keys', () async {
      final app = project('app');
      final result = await cli(
        ['init'],
        environment: machine('a'),
        project: app,
      );
      expect(result.exitCode, 2);
      expect(result.stderr, contains('HOST_UNSUPPORTED'));
      expect(File(p.join(app, 'flutter_patcher.yaml')).existsSync(), false);
    });
    return;
  }

  test('init keeps the private key in the key store, the public key in the project', () async {
    final env = machine('a');
    final app = project('app');
    final created = report(await cli(['init'], environment: env, project: app));
    expect(created['status'], 'keys_created');
    final stored = File(created['key_store'] as String);
    expect(
      p.isWithin(p.join(env['HOME']!, '.flutter_patcher', 'keys'), stored.path),
      true,
    );
    final bundle = KeyBundle.decode(stored.readAsStringSync());
    expect(created['public_key'], bundle.publicKey);
    expect(yaml(app), contains('trust:\n  patch: ${bundle.publicKey}\n'));
    expect(yaml(app), isNot(contains('root:')));
    final secret = base64Encode(bundle.seed);
    expect(created.toString(), isNot(contains(secret)));
    expect(yaml(app), isNot(contains(secret)));
    expect(yaml(app), contains('# store:'));
    if (Platform.isWindows) {
      final acl =
          Process.runSync('icacls', [stored.parent.path]).stdout as String;
      expect(acl, contains(Platform.environment['USERNAME']!));
      expect(acl, isNot(contains('BUILTIN\\Users')));
      expect(acl, isNot(contains('Everyone')));
    } else {
      expect(stored.statSync().mode & 0x1ff, 0x180); // 0600
      expect(stored.parent.statSync().mode & 0x1ff, 0x1c0); // 0700
    }

    // A new key for a project that has one would split its hosts.
    final again = await cli(['init'], environment: env, project: app);
    expect(again.exitCode, 2);
    expect(again.stderr, contains('KEYS_ALREADY_CONFIGURED'));
    expect(
      KeyBundle.decode(stored.readAsStringSync()).encode(),
      bundle.encode(),
    );

    final status = report(
      await cli(['status'], environment: env, project: app),
    );
    expect(status['public_key'], bundle.publicKey);
    expect(status['private_key'], 'key store');
  });

  test('a project without a key signs nothing', () async {
    final status = report(
      await cli(['status'], environment: machine('a'), project: project('app')),
    );
    expect(status['public_key'], isNull);
    expect(status['private_key'], 'none');
  });

  test(
    'the key moves to another machine by file, and to CI by one line',
    () async {
      final first = machine('first'), second = machine('second');
      final app = project('app');
      report(await cli(['init'], environment: first, project: app));
      final backup = p.join(root.path, 'backup.json');
      report(
        await cli(
          ['export', '--out', backup],
          environment: first,
          project: app,
        ),
      );
      if (!Platform.isWindows) {
        expect(File(backup).statSync().mode & 0x1ff, 0x180);
      }
      final refused = await cli(
        ['export', '--out', backup],
        environment: first,
        project: app,
      );
      expect(refused.stderr, contains('KEYS_OUTPUT_EXISTS'));

      // A clone on another machine has the public key but not the private one.
      final clone = project('clone');
      File(p.join(clone, 'flutter_patcher.yaml')).writeAsStringSync(yaml(app));
      expect(
        report(
          await cli(['status'], environment: second, project: clone),
        )['private_key'],
        'none',
      );
      final imported = report(
        await cli(['import', backup], environment: second, project: clone),
      );
      expect(imported['status'], 'keys_imported');
      expect(
        report(
          await cli(['status'], environment: second, project: clone),
        )['private_key'],
        'key store',
      );

      final line = await cli(
        ['export', '--base64'],
        environment: first,
        project: app,
      );
      expect(line.exitCode, 0);
      final ci = {
        ...machine('ci'),
        'FLUTTER_PATCHER_KEYS': (line.stdout as String).trim(),
      };
      expect(
        report(
          await cli(['status'], environment: ci, project: clone),
        )['private_key'],
        'FLUTTER_PATCHER_KEYS',
      );
    },
  );

  test(
    'import refuses another project\'s key and configures a new one',
    () async {
      final env = machine('a');
      final app = project('app');
      report(await cli(['init'], environment: env, project: app));
      final stranger = p.join(root.path, 'stranger.json');
      report(await cli(['init', '--out', stranger], environment: env));
      final refused = await cli(
        ['import', stranger],
        environment: env,
        project: app,
      );
      expect(refused.exitCode, 2);
      expect(refused.stderr, contains('KEYS_MISMATCH'));

      final fresh = project('fresh');
      final imported = report(
        await cli(['import', stranger], environment: env, project: fresh),
      );
      expect(imported['config'], isNotNull);
      final bundle = KeyBundle.decode(File(stranger).readAsStringSync());
      expect(yaml(fresh), contains('patch: ${bundle.publicKey}'));
    },
  );

  test('a flutter_patcher 1.0 project keeps its patch key', () async {
    final env = machine('a');
    final app = project('app');
    final seeds = {
      for (final role in ['root', 'publisher', 'patch'])
        role: ed25519GenerateSeed(),
    };
    final patch = KeyBundle(seeds['patch']!).publicKey;
    File(p.join(app, 'flutter_patcher.yaml')).writeAsStringSync(
      'trust:\n'
      '  root: ${base64Encode(ed25519PublicKey(seeds['root']!))}\n'
      '  publisher: ${base64Encode(ed25519PublicKey(seeds['publisher']!))}\n'
      '  patch: $patch\n',
    );
    final bundle = p.join(root.path, 'v1.json');
    File(bundle).writeAsStringSync(
      jsonEncode({
        'format': 'flutter_patcher.keys.v1',
        'keys': {for (final e in seeds.entries) e.key: base64Encode(e.value)},
      }),
    );
    report(await cli(['import', bundle], environment: env, project: app));
    final status = report(
      await cli(['status'], environment: env, project: app),
    );
    expect(status['public_key'], patch);
    expect(status['private_key'], 'key store');
  });

  test('a pre-1.0 key directory is imported, not replaced', () async {
    final env = machine('a');
    final app = project('app');
    final bundle = KeyBundle.generate();
    File(p.join(app, 'flutter_patcher_keys', 'patch', 'private-key.base64'))
      ..createSync(recursive: true)
      ..writeAsStringSync('${base64Encode(bundle.seed)}\n');
    final init = await cli(['init'], environment: env, project: app);
    expect(init.exitCode, 2);
    expect(init.stderr, contains('keys import flutter_patcher_keys'));
    report(
      await cli(
        ['import', p.join(app, 'flutter_patcher_keys')],
        environment: env,
        project: app,
      ),
    );
    expect(yaml(app), contains('patch: ${bundle.publicKey}'));
  });

  test('key generation needs no external tool', () async {
    final app = project('app');
    final result = await cli(
      ['init'],
      environment: {...machine('a'), 'PATH': ''},
      project: app,
    );
    expect(result.exitCode, 0, reason: '${result.stderr}');
  });
}
