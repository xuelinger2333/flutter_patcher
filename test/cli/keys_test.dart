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

  Future<ProcessResult> run(
    List<String> args, {
    required Map<String, String> environment,
    String? project,
  }) => Process.run(dartVm, [
    p.absolute('bin/flutter_patcher.dart'),
    ...args,
    if (project != null) ...['--project', project],
  ], environment: environment);

  Future<ProcessResult> cli(
    List<String> args, {
    required Map<String, String> environment,
    String? project,
  }) => run(['keys', ...args], environment: environment, project: project);

  Future<ProcessResult> init({
    required Map<String, String> environment,
    required String project,
  }) => run(['init'], environment: environment, project: project);

  Map report(ProcessResult result) {
    expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
    return jsonDecode(result.stdout as String) as Map;
  }

  /// A Flutter app's root: init runs only where a pubspec.yaml is.
  String project(String name) {
    final dir = Directory(p.join(root.path, name))..createSync();
    File(p.join(dir.path, 'pubspec.yaml'))
        .writeAsStringSync('name: $name\nversion: 1.0.0+1\n');
    return dir.path;
  }

  String yaml(String project) =>
      File(p.join(project, 'flutter_patcher.yaml')).readAsStringSync();

  test('help and invalid usage', () async {
    final env = machine('a');
    expect((await cli(['--help'], environment: env)).exitCode, 0);
    expect((await run(['init', '--help'], environment: env)).exitCode, 0);
    for (final args in [
      <String>[],
      ['rotate'],
      ['init'],
      ['init', '--out', 'x'],
      ['import', 'x', '--rotate'],
      ['import'],
      ['export'],
      ['export', '--base64', '--out', 'x'],
      ['export', '--base64', '--without-root'],
    ]) {
      final result = await cli(args, environment: env);
      expect(result.exitCode, 2, reason: '$args');
      expect(result.stderr, contains('USAGE_ERROR'), reason: '$args');
    }
    expect(
      (await cli(['init'], environment: env)).stderr,
      contains('flutter_patcher init'),
    );
  });

  if (!HostIdentity.verified.contains(HostIdentity.current().key)) {
    test('unsupported host fails without creating keys', () async {
      final app = project('app');
      final result = await init(environment: machine('a'), project: app);
      expect(result.exitCode, 2);
      expect(result.stderr, contains('HOST_UNSUPPORTED'));
      expect(File(p.join(app, 'flutter_patcher.yaml')).existsSync(), false);
    });
    return;
  }

  test('init creates the settings and the key, with signing off', () async {
    final env = machine('a');
    final app = project('app');
    final created = report(await init(environment: env, project: app));
    expect(created['status'], 'initialized');
    expect(created['config_created'], true);
    expect(created['signing'], false);
    expect(created['private_key'], 'key store');
    expect(created['notice'], contains('trust.enabled'));
    final stored = File(created['key_store'] as String);
    expect(
      p.isWithin(p.join(env['HOME']!, '.flutter_patcher', 'keys'), stored.path),
      true,
    );
    final bundle = KeyBundle.decode(stored.readAsStringSync());
    expect(created['public_key'], bundle.publicKey);
    expect(yaml(app), contains('trust:\n  patch: ${bundle.publicKey}\n'));
    expect(yaml(app), contains('  enabled: false\n'));
    expect(yaml(app), contains('# store:'));
    expect(yaml(app), contains('# baseline_store:'));
    expect(yaml(app), isNot(contains('root:')));
    final secret = base64Encode(bundle.seed);
    expect(created.toString(), isNot(contains(secret)));
    expect(yaml(app), isNot(contains(secret)));
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

    // Run again, init keeps the key: a new one would split the hosts.
    final before = yaml(app);
    final again = report(await init(environment: env, project: app));
    expect(again['config_created'], false);
    expect(again.containsKey('key_store'), false);
    expect(again['public_key'], bundle.publicKey);
    expect(yaml(app), before);
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

  test(
    'init in a clone keeps the project key and names the missing one',
    () async {
      final app = project('app');
      report(await init(environment: machine('first'), project: app));
      final clone = project('clone');
      File(p.join(clone, 'flutter_patcher.yaml')).writeAsStringSync(yaml(app));
      final cloned = report(
        await init(environment: machine('second'), project: clone),
      );
      expect(cloned['public_key'], isNotNull);
      expect(cloned['private_key'], 'none');
      expect(cloned['notice'], contains('keys import'));
      expect(yaml(clone), yaml(app));
    },
  );

  test('init outside a Flutter app changes nothing', () async {
    final empty = (Directory(p.join(root.path, 'empty'))..createSync()).path;
    final result = await init(environment: machine('a'), project: empty);
    expect(result.exitCode, 2);
    expect(result.stderr, contains('CONFIG_INVALID'));
    expect(Directory(empty).listSync(), isEmpty);
  });

  test('init warns about what build would refuse', () async {
    final app = project('app');
    File(p.join(app, 'pubspec.yaml'))
        .writeAsStringSync('name: app\nversion: 1.0.0\n');
    final result = await init(environment: machine('a'), project: app);
    report(result);
    expect(result.stderr, contains('WARNING: BUILD_CONFIG_INVALID'));
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
      report(await init(environment: first, project: app));
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
      report(await init(environment: env, project: app));
      final other = machine('b'), otherApp = project('other');
      report(await init(environment: other, project: otherApp));
      final stranger = p.join(root.path, 'stranger.json');
      report(
        await cli(
          ['export', '--out', stranger],
          environment: other,
          project: otherApp,
        ),
      );
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
      expect(yaml(fresh), contains('enabled: false'));
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
    // Its hosts were always signed, so they stay signed.
    final initialized = report(await init(environment: env, project: app));
    expect(initialized['public_key'], patch);
    expect(initialized['signing'], true);
  });

  test('a pre-1.0 key directory is imported, not replaced', () async {
    final env = machine('a');
    final app = project('app');
    final bundle = KeyBundle.generate();
    File(p.join(app, 'flutter_patcher_keys', 'patch', 'private-key.base64'))
      ..createSync(recursive: true)
      ..writeAsStringSync('${base64Encode(bundle.seed)}\n');
    final first = await init(environment: env, project: app);
    expect(first.exitCode, 2);
    expect(first.stderr, contains('keys import flutter_patcher_keys'));
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
    final result = await init(
      environment: {...machine('a'), 'PATH': ''},
      project: app,
    );
    expect(result.exitCode, 0, reason: '${result.stderr}');
  });
}
