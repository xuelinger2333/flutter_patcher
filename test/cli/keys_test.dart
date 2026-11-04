// Runs the CLI in subprocesses, each compiling it first: slow under load.
@Timeout(Duration(minutes: 3))
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'host_tools.dart';

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
      ['init', 'extra'],
      ['init', '--force'],
      ['import'],
      ['export'],
      ['export', '--base64', '--out', 'x'],
      ['init', '--role', 'patch'],
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

  test(
    'init keeps private keys in the key store, public keys in the project',
    () async {
      final env = machine('a');
      final app = project('app');
      final created = report(
        await cli(['init'], environment: env, project: app),
      );
      expect(created['status'], 'keys_created');
      final stored = File(created['key_store'] as String);
      expect(
        p.isWithin(
          p.join(env['HOME']!, '.flutter_patcher', 'keys'),
          stored.path,
        ),
        true,
      );
      final bundle = KeyBundle.decode(stored.readAsStringSync());
      final publicKeys = created['public_keys'] as Map;
      for (final role in KeyRole.values) {
        expect(publicKeys[role.name], bundle.publicKey(role));
        expect(yaml(app), contains('${role.name}: ${bundle.publicKey(role)}'));
        final secret = base64Encode(bundle.seeds[role]!);
        expect(created.toString(), isNot(contains(secret)));
        expect(yaml(app), isNot(contains(secret)));
      }
      expect(yaml(app), contains('# store:'));
      expect(
        Directory(p.join(app, 'flutter_patcher_keys')).existsSync(),
        false,
      );
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

      // New keys for a project that has keys would split its hosts.
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
      for (final role in KeyRole.values) {
        expect(status['keys'][role.name], {
          'public_key': bundle.publicKey(role),
          'private_key': 'key store',
        });
      }
    },
  );

  test('keys move to another machine by file, and to CI by one line', () async {
    final first = machine('first'), second = machine('second');
    final app = project('app');
    report(await cli(['init'], environment: first, project: app));
    final backup = p.join(root.path, 'backup.json');
    report(
      await cli(['export', '--out', backup], environment: first, project: app),
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

    // A clone on another machine has the public keys but no private ones.
    final clone = project('clone');
    File(p.join(clone, 'flutter_patcher.yaml')).writeAsStringSync(yaml(app));
    final before = report(
      await cli(['status'], environment: second, project: clone),
    );
    expect(before['keys']['patch']['private_key'], 'none');
    final imported = report(
      await cli(['import', backup], environment: second, project: clone),
    );
    expect(imported['status'], 'keys_imported');
    final after = report(
      await cli(['status'], environment: second, project: clone),
    );
    expect(after['keys']['root']['private_key'], 'key store');

    final line = await cli(
      ['export', '--base64', '--without-root'],
      environment: first,
      project: app,
    );
    expect(line.exitCode, 0);
    final ci = {
      ...machine('ci'),
      'FLUTTER_PATCHER_KEYS': (line.stdout as String).trim(),
    };
    final status = report(
      await cli(['status'], environment: ci, project: clone),
    );
    expect(status['keys']['root']['private_key'], 'none');
    expect(status['keys']['publisher']['private_key'], 'FLUTTER_PATCHER_KEYS');
    expect(status['keys']['patch']['private_key'], 'FLUTTER_PATCHER_KEYS');
  });

  test(
    'import refuses another project\'s keys and configures a new one',
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
      expect(
        yaml(fresh),
        contains('patch: ${bundle.publicKey(KeyRole.patch)}'),
      );
    },
  );

  test('a pre-1.0 key directory is imported, not replaced', () async {
    final env = machine('a');
    final app = project('app');
    final bundle = KeyBundle.generate();
    for (final role in KeyRole.values) {
      File(p.join(app, 'flutter_patcher_keys', role.name, 'private-key.base64'))
        ..createSync(recursive: true)
        ..writeAsStringSync('${base64Encode(bundle.seeds[role]!)}\n');
    }
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
    expect(yaml(app), contains('root: ${bundle.publicKey(KeyRole.root)}'));
  });

  test('the publisher key rotates to a new one', () async {
    final env = machine('a');
    final app = project('app');
    report(await cli(['init'], environment: env, project: app));
    final next = p.join(root.path, 'publisher.json');
    final created = report(
      await cli([
        'init',
        '--out',
        next,
        '--role',
        'publisher',
      ], environment: env),
    );
    final publisher = (created['public_keys'] as Map)['publisher'] as String;
    expect((created['public_keys'] as Map).keys, ['publisher']);
    final rotated = report(
      await cli(['import', next, '--rotate'], environment: env, project: app),
    );
    expect(rotated['status'], 'keys_rotated');
    expect(yaml(app), contains('publisher: $publisher'));
    final status = report(
      await cli(['status'], environment: env, project: app),
    );
    expect(status['keys']['publisher'], {
      'public_key': publisher,
      'private_key': 'key store',
    });
    expect(status['keys']['root']['private_key'], 'key store');
    final again = await cli(
      ['import', next, '--rotate'],
      environment: env,
      project: app,
    );
    expect(again.stderr, contains('KEYS_ALREADY_CONFIGURED'));
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
