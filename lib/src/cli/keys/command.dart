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
        'init: write the new key to this new file only, leaving the key '
        'store and the project alone. export: the new file to write.',
  )
  ..addOption(
    'role',
    allowed: ['patch'],
    help: 'init --out: the key to generate; the patch key is the only one.',
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
    help: 'export: accepted for flutter_patcher 1.0 scripts; bundles hold no root key.',
  )
  ..addOption('key-file', help: 'status: also consider this key bundle.');

const _usage =
    'Use keys init [--out <file>], keys export (--out <file> | --base64), '
    'keys import <file|directory|-> or keys status.';

/// Signing: creates, moves and inspects a project's patch key. Its public
/// key lives in flutter_patcher.yaml (`trust.patch`); hosts built while it
/// is there accept only patch files it signed. Its private key lives in the
/// user's key store, a CI secret or a signing service, never in the project.
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
    '--role only names the key keys init --out generates.',
  );
  final Map<String, Object?> report;
  switch (action) {
    case 'init':
      report = await _init(project, args['out'] as String?);
    case 'export':
      final line = await _export(project, args);
      if (line != null) {
        stdout.writeln(line);
        return 0;
      }
      report = {'status': 'keys_exported', 'file': p.absolute(args['out'])};
    case 'import':
      report = await _import(project, rest[1]);
    default:
      report = await _status(project, args['key-file'] as String?);
  }
  stdout.writeln(jsonEncode({'command': 'keys $action', ...report}));
  return 0;
}

Future<Map<String, Object?>> _init(String project, String? out) async {
  final bundle = KeyBundle.generate();
  if (out != null) {
    await writeNewKeyFile(out, bundle.encode());
    return {
      'status': 'keys_created',
      'file': p.absolute(out),
      'public_key': bundle.publicKey,
    };
  }
  final config = await ProjectConfig.load(project);
  final legacy = p.join(project, 'flutter_patcher_keys');
  require(
    config.patchKey == null && !await Directory(legacy).exists(),
    'KEYS_ALREADY_CONFIGURED',
    config.patchKey == null
        ? 'This project has keys in $legacy; move them to the key store '
              'with `flutter_patcher keys import flutter_patcher_keys`.'
        : '${config.path} already names this project\'s patch key; hosts '
              'built with it would not accept files signed by a new one. '
              'Bring the key to this machine with `flutter_patcher keys '
              'import <bundle>`.',
  );
  final stored = await saveKeyStore(bundle);
  await config.writeTrust(bundle.publicKey);
  return {
    'status': 'keys_created',
    'key_store': stored,
    'config': config.path,
    'public_key': bundle.publicKey,
    'notice':
        'Hosts built from now on accept only patch files signed by this key. '
        'Copy it to other machines with `flutter_patcher keys export`.',
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
  final bundle = await loadKeyStore(await _patchKey(project));
  require(
    bundle != null,
    'KEYS_NOT_FOUND',
    'The key store of this machine does not hold this project\'s patch key.',
  );
  if (out == null) return base64Encode(utf8.encode(bundle!.encode()));
  await writeNewKeyFile(out, bundle!.encode());
  return null;
}

Future<Map<String, Object?>> _import(String project, String source) async {
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
  if (config.patchKey == null) {
    final stored = await saveKeyStore(bundle);
    await config.writeTrust(bundle.publicKey);
    return {
      'status': 'keys_imported',
      'key_store': stored,
      'config': config.path,
      'public_key': bundle.publicKey,
    };
  }
  require(
    bundle.publicKey == config.patchKey,
    'KEYS_MISMATCH',
    'This is not the patch key ${config.path} names.',
  );
  return {
    'status': 'keys_imported',
    'key_store': await saveKeyStore(bundle),
    'public_key': bundle.publicKey,
  };
}

Future<Map<String, Object?>> _status(String project, String? keyFile) async {
  final config = await ProjectConfig.load(project);
  final key = config.patchKey;
  return {
    'config': config.path,
    'public_key': key,
    'private_key': key == null
        ? 'none'
        : await Keyring(
            key,
            keyFile: keyFile,
            command: config.signingCommand,
          ).describe(),
  };
}

Future<String> _patchKey(String project) async {
  final config = await ProjectConfig.load(project);
  require(
    config.patchKey != null,
    'KEYS_NOT_CONFIGURED',
    '${config.path} names no patch key; run `flutter_patcher keys init`, or '
        '`flutter_patcher keys import` with the project\'s key bundle.',
  );
  return config.patchKey!;
}
