import 'dart:convert';
import 'dart:io';
import 'package:args/args.dart';
import 'package:path/path.dart' as p;
import '../core.dart';
import '../sdk/artifacts.dart';
import '../sdk/environment.dart';
import '../baseline/repository.dart';
import '../baseline/store.dart';
import 'pipeline.dart';

Future<int> patchCommand(ArgResults args) async {
  RandomAccessFile? lock;
  try {
    require(args.rest.length == 1 && args.rest.single == 'android',
        'USAGE_ERROR', 'Use patch android');
    require(args['strategy'] == 'bytecode', 'PATCH_STRATEGY_UNSUPPORTED',
        'Select --strategy bytecode; v1 SO tooling is unchanged');
    require(
        Platform.isLinux, 'HOST_UNSUPPORTED', 'M1 patch requires Linux x64');
    String value(String name) {
      final v = args[name] as String?;
      require(
          v != null && v.isNotEmpty, 'PATCH_CONFIG_INVALID', 'Missing --$name');
      return v!;
    }

    final home = Platform.environment['HOME'];
    require(home != null, 'CONFIG_INVALID', 'HOME is not set');
    final base = p.join(home!, '.flutter_patcher'),
        local = p.absolute('.dart_tool/flutter_patcher');
    final cache = p.normalize(p.absolute(args['cache-dir'] as String? ?? base));
    require(
        cache == base ||
            p.isWithin(base, cache) ||
            cache == local ||
            p.isWithin(local, cache),
        'CONFIG_INVALID',
        'Use a managed cache');
    await rejectLinks(cache);
    await Directory(cache).create(recursive: true);
    final commands = Commands(cache);
    require((await commands.run('uname', ['-m'])).trim() == 'x86_64',
        'HOST_UNSUPPORTED', 'M1 patch requires Linux x64');
    final offline = args['offline'] == true;
    require(!(offline && args['refresh-tools'] == true), 'CONFIG_INVALID',
        'Cannot refresh tools offline');
    final project =
        p.absolute(args['project'] as String? ?? Directory.current.path);
    final request = PatchRequest(
        project: project,
        fingerprint: value('fingerprint'),
        privateKey: await File(value('private-key')).readAsString(),
        output: p.absolute(args['out'] as String? ??
            p.join(project, '.dart_tool/flutter_patcher/patches',
                DateTime.now().microsecondsSinceEpoch.toString())),
        seq: int.tryParse(value('seq')) ?? -1,
        minBuild: int.tryParse(value('version-code')) ?? -1,
        previousSeq: args['previous-seq'] == null
            ? null
            : int.tryParse(value('previous-seq')) ?? -1,
        target: args['target'] as String,
        offline: offline);
    await request.validate();
    await rejectLinks(p.join(cache, 'doctor.lock'));
    lock = await File(p.join(cache, 'doctor.lock')).open(mode: FileMode.append);
    await lock.lock(FileLock.blockingExclusive);
    final sdk = await identify(
        await Directory(findFlutter(args['flutter-sdk'] as String?))
            .resolveSymbolicLinks(),
        commands);
    require(sdk.root != p.join(cache, 'flutter', sdk.version), 'CONFIG_INVALID',
        'Select the stock SDK');
    final store = ArtifactStore(
        cache,
        Uri.parse(args['artifacts-url'] as String),
        Uri.parse(args['supported-versions-url'] as String),
        Downloads(offline: offline));
    await store.checkSupport(sdk.version);
    final engine = await store.obtain('engine', sdk);
    await store.obtain('tools', sdk, refresh: args['refresh-tools'] == true);
    final managed = await EnvironmentBuilder(cache, commands, offline: offline)
        .prepare(sdk, store, engine);
    final baselines = BaselineRepository(
        p.join(cache, 'baselines'),
        offline
            ? null
            : BaselineStore.open(Uri.parse(value('baseline-store')), commands));
    final result = await PatchPipeline(
            commands,
            sdk,
            managed,
            store.file(
                sdk, 'tools', 'flutter_patcher_tools-${sdk.version}.dill'),
            cache,
            baselines)
        .patch(request);
    stdout.writeln(jsonEncode({'command': 'patch', ...result}));
    return 0;
  } catch (error) {
    final failure = error is Failure
        ? error
        : Failure('PATCH_FAILED', 'Patch failed (${error.runtimeType})');
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
