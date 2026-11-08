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
import 'patch/package.dart' show PatchDraft, newModuleId;
import 'patch/pipeline.dart';

/// `patch`: the patch layer makes a draft from the source and the host's
/// baseline, never touching a key; this command then seals it as the file
/// devices take, signing it when the host trusts a key this machine has.
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
    final request = PatchRequest(
      project: project,
      fingerprint: args['fingerprint'] as String?,
      flavor: flavor,

      output: p.absolute(
        args['out'] as String? ??
            p.join(
              project,
              '.dart_tool/flutter_patcher/patches',
              DateTime.now().microsecondsSinceEpoch.toString(),
            ),
      ),

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
    final result = await PatchPipeline(
      commands,
      sdk,
      managed,
      store.file(sdk, 'tools', 'flutter_patcher_tools-${sdk.version}.dill'),
      cache,
      baselines,
      engine: engine,
    ).patch(request, resolved);
    for (final warning in result['warnings'] as List? ?? const []) {
      stderr.writeln('WARNING: ${warning['code']}: ${warning['message']}');
    }
    final file = await sealOutput(result, config);
    stdout.writeln(jsonEncode({'command': 'patch', ...result, ...file}));
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

/// Seals the draft of a patch output as `<output>/<fileName>`, numbered now.
/// A host that trusts a key this machine lacks gets its file from publish,
/// on a machine that has it.
Future<Map<String, Object?>> sealOutput(
  Map<String, Object?> result,
  ProjectConfig config,
) async {
  final output = result['output'] as String;
  final key = result['patch_key'] as String;
  final name = patchFileName(Map<String, String>.from(result['scope'] as Map));
  final ring = key == '-' ? null : Keyring(key, command: config.signingCommand);
  if (ring != null && await ring.describe() == 'none') {
    return {
      'file': null,
      'notice':
          'This host accepts only files signed by its patch key, which this '
          'machine does not have: run `flutter_patcher publish --patch '
          '$output` where it is, or `flutter_patcher keys import` it here.',
    };
  }
  final seq = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  final bytes = await sealPatch(
    await PatchDraft.read(output),
    signer: await ring?.signer(),
    seq: seq,
  );
  final file = p.join(output, name);
  await File(file).writeAsBytes(bytes, flush: true);
  return {
    'file': file,
    'seq': seq,
    'sealed_at': DateTime.fromMillisecondsSinceEpoch(
      seq * 1000,
      isUtc: true,
    ).toIso8601String(),
    'signed': ring != null,
  };
}
