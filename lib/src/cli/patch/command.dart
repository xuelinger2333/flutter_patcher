import 'dart:convert';
import 'dart:io';
import 'package:args/args.dart';
import 'package:path/path.dart' as p;
import '../core.dart';
import '../sdk/artifacts.dart';
import '../sdk/host.dart';
import '../sdk/environment.dart';
import '../baseline/repository.dart';
import '../baseline/store.dart';
import '../build/host_policy.dart';
import '../project.dart';
import '../publish/pipeline.dart' show nextSequence;
import '../publish/store.dart';
import '../publish/transaction.dart';
import 'pipeline.dart';

Future<int> patchCommand(ArgResults args) async {
  RandomAccessFile? lock;
  try {
    require(
        args.rest.length == 1 &&
            const ['android', 'ios'].contains(args.rest.single),
        'USAGE_ERROR',
        'Use patch android or patch ios');
    // iOS patches compile Dart only, so every supported host makes them.
    final platform = args.rest.single;

    requireSupportedHost(target: platform);
    String value(String name) {
      final v = args[name] as String?;
      require(
          v != null && v.isNotEmpty, 'PATCH_CONFIG_INVALID', 'Missing --$name');
      return v!;
    }

    final cache = managedCache(args['cache-dir'] as String?);
    await rejectLinks(cache);
    await Directory(cache).create(recursive: true);
    final commands = Commands(cache);
    final offline = args['offline'] == true;
    final project =
        p.absolute(args['project'] as String? ?? Directory.current.path);
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
        commands);
    require(sdk.root != p.join(cache, 'flutter', sdk.version), 'CONFIG_INVALID',
        'Select the stock SDK');
    trace('identify sdk');
    final baselines = BaselineRepository(
        p.join(cache, 'baselines'),
        offline
            ? null
            : BaselineStore.open(
                Uri.parse(
                    args['baseline-store'] as String? ?? config.baselineStore),
                commands));
    final resolved = await baselines.resolve(flavor, versionCode,
        abi: abi,
        expectedFingerprint: args['fingerprint'] as String?,
        sdkRoot: sdk.root);
    final request = PatchRequest(
        project: project,
        fingerprint: args['fingerprint'] as String?,
        flavor: flavor,
        privateKey: await File(args['private-key'] as String? ??
                config.key('patch', private: true))
            .readAsString(),
        output: p.absolute(args['out'] as String? ??
            p.join(project, '.dart_tool/flutter_patcher/patches',
                DateTime.now().microsecondsSinceEpoch.toString())),
        seq: args['seq'] == null
            ? await _nextSequence(config, resolved, commands, cache)
            : int.tryParse(value('seq')) ?? -1,
        minBuild: int.tryParse(versionCode) ?? -1,
        previousSeq: args['previous-seq'] == null
            ? null
            : int.tryParse(value('previous-seq')) ?? -1,
        target: args['target'] as String,
        assets: (args['assets'] as List).cast<String>(),
        platform: platform,
        offline: offline);
    await request.validate();
    // A patch uses the releases its host was built with, never newer ones.
    final store = ArtifactStore(
        cache,
        Uri.parse(args['artifacts-url'] as String),
        Uri.parse(args['index-url'] as String),
        Downloads(offline: offline))
      ..select(builtWith(resolved));
    // The Android engine serves only SO rebuilds; an iOS patch needs none.
    final engine =
        platform == 'android' ? await store.obtain('engine', sdk) : null;
    await store.obtain('tools', sdk);
    trace('artifacts');
    final managed = await EnvironmentBuilder(cache, commands, offline: offline)
        .prepare(sdk, store, android: engine);
    trace('managed sdk');
    final result = await PatchPipeline(
            commands,
            sdk,
            managed,
            store.file(
                sdk, 'tools', 'flutter_patcher_tools-${sdk.version}.dill'),
            cache,
            baselines,
            engine: engine)
        .patch(request, resolved);
    for (final warning in result['warnings'] as List? ?? const []) {
      stderr.writeln('WARNING: ${warning['code']}: ${warning['message']}');
    }
    stdout.writeln(jsonEncode({'command': 'patch', ...result}));
    return 0;
  } catch (error) {
    final failure = error is Failure
        ? error
        : unexpectedFailure('PATCH_FAILED', 'Patch', error);
    stderr.writeln(jsonEncode({
      'command': 'patch',
      'status': 'failed',
      'code': failure.code,
      'message': failure.message,
      if (failure is PatchFailure) 'details': failure.details
    }));
    return 2;
  } finally {
    if (lock != null) {
      await lock.unlock();
      await lock.close();
    }
  }
}

/// The next sequence the configured publication store accepts for
/// [resolved]'s fingerprint.
Future<int> _nextSequence(ProjectConfig config, ResolvedRelease resolved,
    Commands commands, String cache) async {
  final store = config['store'];
  require(store != null, 'PATCH_CONFIG_INVALID',
      'Pass --seq, or set store in ${ProjectConfig.file} so the next sequence '
      'is read from what was published.');
  final work = await Directory(cache).createTemp('patch-seq-');
  try {
    final catalog = await PublicationTransaction(
            openPublishStore(Uri.parse(store!), commands, work.path),
            resolved.receipt['application_id'] as String)
        .snapshot();
    return nextSequence(catalog, resolved.fingerprint);
  } finally {
    await work.delete(recursive: true);
  }
}
