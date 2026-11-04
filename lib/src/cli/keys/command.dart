import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:path/path.dart' as p;

import '../core.dart';
import '../project.dart';
import '../sdk/host.dart';
import 'bundle.dart';
import 'keyring.dart';

ArgParser keysOptions() => ArgParser()
  ..addFlag('help', abbr: 'h', negatable: false)
  ..addOption(
    'project',
    help: 'Application directory; default the current one.',
  )
  ..addOption(
    'out',
    help:
        'init: write the new keys to this new file only, leaving the key '
        'store and the project alone. export: the new file to write.',
  )
  ..addOption(
    'role',
    allowed: [for (final role in KeyRole.values) role.name],
    help:
        'init --out: generate only this key, such as a publisher key to '
        'rotate to.',
  )
  ..addFlag(
    'base64',
    negatable: false,
    help:
        'export: print the key bundle as one base64 line, for a CI secret '
        '(${Keyring.environmentVariable}).',
  )
  ..addFlag(
    'without-root',
    negatable: false,
    help: 'export: leave out the root key, which only trust updates need.',
  )
  ..addFlag(
    'rotate',
    negatable: false,
    help:
        'import: adopt the bundle\'s publisher key in place of the '
        'current one, once its trust update is published.',
  )
  ..addOption('key-file', help: 'status: also consider this key bundle.');

const _usage =
    'Use keys init [--out <file> [--role <role>]], keys export '
    '(--out <file> | --base64) [--without-root], keys import '
    '<file|directory|-> [--rotate] or keys status.';

/// Creates, moves and inspects a project's keys. Its public keys live in
/// flutter_patcher.yaml; its private keys live in the user's key store, a
/// CI secret or a signing service, never in the project.
Future<int> keysCommand(ArgResults args) async {
  final rest = args.rest;
  final action = rest.isEmpty ? null : rest.first;
  require(
    (rest.length == 1 && {'init', 'export', 'status'}.contains(action)) ||
        (rest.length == 2 && action == 'import'),
    'USAGE_ERROR',
    _usage,
  );
  requireSupportedHost();
  final project = p.absolute(
    args['project'] as String? ?? Directory.current.path,
  );
  require(
    args['role'] == null || (action == 'init' && args['out'] != null),
    'USAGE_ERROR',
    '--role only selects the key keys init --out generates.',
  );
  final Map<String, Object?> report;
  switch (action) {
    case 'init':
      report = await _init(project, args['out'] as String?, args['role']);
    case 'export':
      final line = await _export(project, args);
      if (line != null) {
        stdout.writeln(line);
        return 0;
      }
      report = {'status': 'keys_exported', 'file': p.absolute(args['out'])};
    case 'import':
      report = await _import(project, rest[1], args['rotate'] == true);
    default:
      report = await _status(project, args['key-file'] as String?);
  }
  stdout.writeln(jsonEncode({'command': 'keys $action', ...report}));
  return 0;
}

Future<Map<String, Object?>> _init(
  String project,
  String? out,
  Object? role,
) async {
  if (out != null) {
    final bundle = role == null
        ? KeyBundle.generate()
        : KeyBundle({
            KeyRole.values.byName(role as String):
                KeyBundle.generate().seeds[KeyRole.values.byName(role)]!,
          });
    await writeNewKeyFile(out, bundle.encode());
    return {
      'status': 'keys_created',
      'file': p.absolute(out),
      'public_keys': _publicKeys(bundle),
    };
  }
  final config = await ProjectConfig.load(project);
  final legacy = p.join(project, 'flutter_patcher_keys');
  require(
    config.anchors == null && !await Directory(legacy).exists(),
    'KEYS_ALREADY_CONFIGURED',
    config.anchors == null
        ? 'This project has keys in $legacy; move them to the key store '
              'with `flutter_patcher keys import flutter_patcher_keys`.'
        : '${config.path} already names this project\'s keys; new keys '
              'would not be trusted by the hosts already built. Bring the '
              'existing keys to this machine with `flutter_patcher keys '
              'import <bundle>`.',
  );
  final bundle = KeyBundle.generate();
  final stored = await saveKeyStore(bundle, bundle.anchors);
  await config.writeTrust(bundle.anchors);
  return {
    'status': 'keys_created',
    'key_store': stored,
    'config': config.path,
    'public_keys': _publicKeys(bundle),
    'notice':
        'Commit ${ProjectConfig.file}. Back up the private keys now with '
        '`flutter_patcher keys export --out <file>`: a lost root or patch key '
        'cannot be replaced for hosts already shipped.',
  };
}

/// The base64 line to print, or null after writing --out.
Future<String?> _export(String project, ArgResults args) async {
  final out = args['out'] as String?;
  require(
    (out == null) == (args['base64'] == true),
    'USAGE_ERROR',
    'Use keys export --out <new file>, or keys export --base64.',
  );
  final anchors = (await ProjectConfig.load(project)).requireAnchors();
  var bundle = await loadKeyStore(anchors);
  require(
    bundle != null,
    'KEYS_NOT_FOUND',
    'The key store of this machine has no keys for this project.',
  );
  if (args['without-root'] == true) {
    require(
      bundle!.seeds.keys.any((role) => role != KeyRole.root),
      'KEYS_NOT_FOUND',
      'The key store holds only the root key of this project.',
    );
    bundle = bundle.without(KeyRole.root);
  }
  if (out == null) return base64Encode(utf8.encode(bundle!.encode()));
  await writeNewKeyFile(out, bundle!.encode());
  return null;
}

Future<Map<String, Object?>> _import(
  String project,
  String source,
  bool rotate,
) async {
  final KeyBundle bundle;
  if (source == '-') {
    bundle = KeyBundle.decode(await stdin.transform(utf8.decoder).join());
  } else if (await Directory(source).exists()) {
    bundle = await KeyBundle.readDirectory(source);
  } else {
    await rejectLinks(source);
    require(
      await File(source).exists(),
      'KEYS_NOT_FOUND',
      'No key bundle at $source.',
    );
    bundle = KeyBundle.decode(await File(source).readAsString());
  }
  final config = await ProjectConfig.load(project);
  final anchors = config.anchors;
  final roles = [for (final role in bundle.seeds.keys) role.name];
  if (anchors == null) {
    require(
      !rotate,
      'KEYS_NOT_CONFIGURED',
      'Only a project with keys can rotate its publisher key.',
    );
    final stored = await saveKeyStore(bundle, bundle.anchors);
    await config.writeTrust(bundle.anchors);
    return {
      'status': 'keys_imported',
      'roles': roles,
      'key_store': stored,
      'config': config.path,
      'notice': 'Commit ${ProjectConfig.file}.',
    };
  }
  if (!rotate) {
    require(
      bundle.matches(anchors),
      'KEYS_MISMATCH',
      'These keys are not the ones ${config.path} names.',
    );
    return {
      'status': 'keys_imported',
      'roles': roles,
      'key_store': await saveKeyStore(bundle, anchors),
    };
  }
  require(
    bundle.seeds[KeyRole.publisher] != null,
    'KEYS_BUNDLE_INVALID',
    'A rotation imports a publisher key.',
  );
  final rotated = anchors.withPublisher(bundle.publicKey(KeyRole.publisher));
  require(
    rotated.publisher != anchors.publisher,
    'KEYS_ALREADY_CONFIGURED',
    'This is already the project\'s publisher key.',
  );
  final stored = await saveKeyStore(bundle, rotated, replace: true);
  await config.writePublisher(rotated.publisher);
  return {
    'status': 'keys_rotated',
    'key_store': stored,
    'config': config.path,
    'publisher': rotated.publisher,
    'notice': 'Commit ${ProjectConfig.file}.',
  };
}

Future<Map<String, Object?>> _status(String project, String? keyFile) async {
  final config = await ProjectConfig.load(project);
  final ring = Keyring.forProject(config, keyFile: keyFile);
  final sources = await ring.describe();
  return {
    'config': config.path,
    'keys': {
      for (final role in KeyRole.values)
        role.name: {
          'public_key': ring.anchors.of(role),
          'private_key': sources[role],
        },
    },
  };
}

Map<String, String> _publicKeys(KeyBundle bundle) => {
  for (final role in bundle.seeds.keys) role.name: bundle.publicKey(role),
};
