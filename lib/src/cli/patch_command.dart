import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:path/path.dart' as p;

import 'core.dart';
import 'sdk/artifacts.dart';
import 'sdk/host.dart';
import 'sdk/environment.dart';
import 'baseline/repository.dart';
import 'baseline/store.dart';
import 'build/host_policy.dart';
import 'keys/keyring.dart';
import 'project.dart';
import 'publish/seal.dart';
import '../patch_file.dart';
import 'patch/outputs.dart';
import 'patch/package.dart' show PatchDraft, newModuleId;
import 'patch/pipeline.dart';

/// `patch`: the patch layer makes a draft from the source and the host's
/// baseline, never touching a key; this command then seals it as the file
/// devices take, signing it when the host trusts a key this machine has.
/// With `--withdraw` it seals a withdrawal of the host instead.
Future<int> patchCommand(ArgResults args) async {
  RandomAccessFile? lock;
  try {
    require(
      args.rest.length == 1 &&
          const ['android', 'ios'].contains(args.rest.single),
      'USAGE_ERROR',
      'Use patch android or patch ios',
    );
    // iOS patches compile Dart only, so every supported host makes them.
    final platform = args.rest.single;

    requireSupportedHost(target: platform);
    final withdraw = args['withdraw'] == true;
    require(
      !withdraw || !(args.wasParsed('target') || args.wasParsed('assets')),
      'USAGE_ERROR',
      'patch --withdraw compiles nothing; drop --target and --assets.',
    );

    final cache = managedCache(args['cache-dir'] as String?);
    await rejectLinks(cache);
    await Directory(cache).create(recursive: true);
    final commands = Commands(cache);
    final offline = args['offline'] == true;
    final project = p.absolute(
      args['project'] as String? ?? Directory.current.path,
    );
    final config = await ProjectConfig.load(project);
    final flavor = args['flavor'] as String? ?? 'default';
    // The host this patch is for: by default the build this project builds.
    final versionCode =
        args['version-code'] as String? ?? await buildNumber(project);
    final abi = platform == 'ios' ? 'ios-arm64' : 'arm64-v8a';
    await rejectLinks(p.join(cache, 'doctor.lock'));
    lock = await File(p.join(cache, 'doctor.lock')).open(mode: FileMode.append);
    await lock.lock(FileLock.blockingExclusive);
    final sdk = await identify(
      await Directory(findFlutter(args['flutter-sdk'] as String?))
          .resolveSymbolicLinks(),
      commands,
    );
    require(
      sdk.root != p.join(cache, 'flutter', sdk.version),
      'CONFIG_INVALID',
      'Select the stock SDK',
    );
    trace('identify sdk');
    final baselines = BaselineRepository(
      p.join(cache, 'baselines'),
      offline
          ? null
          : BaselineStore.open(
              Uri.parse(
                args['baseline-store'] as String? ?? config.baselineStore,
              ),
              commands,
            ),
    );
    final resolved = await baselines.resolve(
      flavor,
      versionCode,
      abi: abi,
      expectedFingerprint: args['fingerprint'] as String?,
      sdkRoot: sdk.root,
    );
    final output = p.absolute(
      args['out'] as String? ??
          p.join(
            patchOutputsRoot(project),
            DateTime.now().microsecondsSinceEpoch.toString(),
          ),
    );
    if (withdraw) {
      final policy = await hostPolicyOf(resolved);
      final result = await writeWithdrawal(output, {
        'status': 'withdrawal_created',
        'scope': hostScope(policy, resolved.fingerprint),
        'patch_key': policy.patchKey,
        'platform': platform,
        'abi': abi,
        'strategy': resolved.strategy,
        'fingerprint': resolved.fingerprint,
      }, config);
      stdout.writeln(jsonEncode({'command': 'patch', ...result}));
      return 0;
    }
    final request = PatchRequest(
      project: project,
      fingerprint: args['fingerprint'] as String?,
      flavor: flavor,

      output: output,

      // The compiler needs a module identity, not a publication sequence.
      moduleId: newModuleId(),
      minBuild: int.tryParse(versionCode) ?? -1,

      target: args['target'] as String,
      assets: (args['assets'] as List).cast<String>(),
      platform: platform,
      offline: offline,
    );
    await request.validate();
    // A patch uses the releases its host was built with, never newer ones.
    final store = ArtifactStore(
      cache,
      Uri.parse(args['artifacts-url'] as String),
      Uri.parse(args['index-url'] as String),
      Downloads(offline: offline),
    )..select(builtWith(resolved));
    // The Android engine serves only SO rebuilds; an iOS patch needs none.
    final engine = platform == 'android'
        ? await store.obtain('engine', sdk)
        : null;
    await store.obtain('tools', sdk);
    trace('artifacts');
    final managed = await EnvironmentBuilder(
      cache,
      commands,
      offline: offline,
    ).prepare(sdk, store, android: engine);
    trace('managed sdk');
    final result =
        await PatchPipeline(
          commands,
          sdk,
          managed,
          store.file(sdk, 'tools', 'flutter_patcher_tools-${sdk.version}.dill'),
          cache,
          baselines,
          engine: engine,
        ).patch(
          request,
          resolved,
          seal: (dir, report) => sealOutput(dir, report, config),
        );
    for (final warning in result['warnings'] as List? ?? const []) {
      stderr.writeln('WARNING: ${warning['code']}: ${warning['message']}');
    }
    stdout.writeln(jsonEncode({'command': 'patch', ...located(result)}));
    return 0;
  } catch (error) {
    final failure = error is Failure
        ? error
        : unexpectedFailure('PATCH_FAILED', 'Patch', error);
    stderr.writeln(
      jsonEncode({
        'command': 'patch',
        'status': 'failed',
        'code': failure.code,
        'message': failure.message,
        if (failure is PatchFailure) 'details': failure.details,
      }),
    );
    return 2;
  } finally {
    if (lock != null) {
      await lock.unlock();
      await lock.close();
    }
  }
}

/// Seals the draft in [dir], or the withdrawal [report] is, numbered now, as
/// `<dir>/<fileName>`, signing it when the host trusts a key. A host that
/// trusts a key this machine lacks gets no file here: publish makes it on a
/// machine that has the key.
Future<Map<String, Object?>> sealOutput(
  String dir,
  Map<String, Object?> report,
  ProjectConfig config,
) async {
  final key = report['patch_key'] as String;
  final scope = Map<String, String>.from(report['scope'] as Map);
  final ring = key == '-' ? null : Keyring(key, command: config.signingCommand);
  if (ring != null && await ring.describe() == 'none') {
    return {
      'file': null,
      'notice':
          'This host accepts only files signed by its patch key, which this '
          'machine does not have: `flutter_patcher keys import` it here and '
          'patch again, or run `flutter_patcher publish --patch` with this '
          'output where it is.',
    };
  }
  final seq = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  final signer = await ring?.signer();
  final bytes = report['status'] == 'withdrawal_created'
      ? await sealWithdrawal(scope['fingerprint']!, signer: signer, seq: seq)
      : await sealPatch(await PatchDraft.read(dir), signer: signer, seq: seq);
  final name = patchFileName(scope);
  await File(p.join(dir, name)).writeAsBytes(bytes, flush: true);
  return {
    'file': name,
    'seq': seq,
    'sealed_at': DateTime.fromMillisecondsSinceEpoch(
      seq * 1000,
      isUtc: true,
    ).toIso8601String(),
    'signed': ring != null,
  };
}

/// Writes the withdrawal [report] describes as the new output [output].
Future<Map<String, Object?>> writeWithdrawal(
  String output,
  Map<String, Object?> report,
  ProjectConfig config,
) async {
  await rejectLinks(output);
  require(
    await FileSystemEntity.type(output, followLinks: false) ==
        FileSystemEntityType.notFound,
    'PATCH_CONFIG_INVALID',
    '$output already exists',
  );
  final pending = temporaryName(output);
  await Directory(pending).create(recursive: true);
  await writeObject(p.join(pending, 'patch.json'), report);
  final sealed = await sealOutput(pending, report, config);
  await Directory(pending).renameRetry(output);
  return located({...report, 'output': output, ...sealed});
}

/// [result] with its file named by its full path.
Map<String, Object?> located(Map<String, Object?> result) => {
  ...result,
  if (result['file'] case final String name)
    'file': p.join(result['output'] as String, name),
};
