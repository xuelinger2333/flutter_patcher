import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:path/path.dart' as p;

import 'build/host_policy.dart';
import 'core.dart';
import 'keys/bundle.dart';
import 'keys/keyring.dart';
import 'project.dart';
import 'sdk/host.dart';

ArgParser initOptions() => ArgParser()
  ..addFlag('help', abbr: 'h', negatable: false)
  ..addOption(
    'project',
    help: 'Application directory; default the current one.',
  );

/// `init`: prepares a project once. It creates flutter_patcher.yaml with
/// every setting commented out, and the project's patch key with signing
/// off, then warns about what `build` would refuse in the project. Run
/// again, it keeps what exists: a second key would split the project's
/// hosts between two keys.
Future<int> initCommand(ArgResults args) async {
  require(args.rest.isEmpty, 'USAGE_ERROR', 'Use init [--project <dir>].');
  requireSupportedHost();
  final project = p.absolute(
    args['project'] as String? ?? Directory.current.path,
  );
  require(
    await File(p.join(project, 'pubspec.yaml')).exists(),
    'CONFIG_INVALID',
    'No pubspec.yaml in $project; run init in the root of the Flutter app.',
  );
  final created = await (await ProjectConfig.load(project)).create();
  var config = await ProjectConfig.load(project);
  String? keyStore;
  if (config.patchKey == null) {
    final legacy = p.join(project, 'flutter_patcher_keys');
    require(
      !await Directory(legacy).exists(),
      'KEYS_ALREADY_CONFIGURED',
      'This project has keys in $legacy; move them to the key store with '
          '`flutter_patcher keys import flutter_patcher_keys`.',
    );
    final bundle = KeyBundle.generate();
    keyStore = await saveKeyStore(bundle);
    await config.writeTrust(bundle.publicKey);
    config = await ProjectConfig.load(project);
  }
  final privateKey = await Keyring(
    config.patchKey!,
    command: config.signingCommand,
  ).describe();

  // build fails on these; init only says so, since the fix is the user's.
  Future<void> warn(Future<void> Function() check) async {
    try {
      await check();
    } on Failure catch (failure) {
      stderr.writeln('WARNING: ${failure.code}: ${failure.message}');
    }
  }

  await warn(() => buildNumber(project));
  for (final platform in ['android', 'ios']) {
    if (await Directory(p.join(project, platform)).exists()) {
      await warn(() => projectApplicationId(project, platform));
    }
  }

  final notice = privateKey == 'none'
      ? 'This computer has no private key for the project\'s patch key: '
            'run `flutter_patcher keys import <file>` with a bundle from '
            '`flutter_patcher keys export` on a computer that has it.'
      : !config.signingEnabled
      ? 'Signing is off. Before the build you ship, set trust.enabled to '
            'true in ${ProjectConfig.file}.'
      : null;
  stdout.writeln(
    jsonEncode({
      'command': 'init',
      'status': 'initialized',
      'config': config.path,
      'config_created': created,
      'public_key': config.patchKey,
      'key_store': ?keyStore,
      'private_key': privateKey,
      'signing': config.signingEnabled,
      'notice': ?notice,
    }),
  );
  return 0;
}
