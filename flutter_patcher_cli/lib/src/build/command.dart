import 'dart:convert';
import 'dart:io';
import 'package:args/args.dart';
import 'package:path/path.dart' as p;
import '../core.dart';
import '../sdk/android.dart';
import '../sdk/artifacts.dart';
import '../sdk/host.dart';
import '../sdk/environment.dart';
import '../baseline/repository.dart';
import '../baseline/store.dart';
import 'pipeline.dart';
import 'host_policy.dart';

Future<int> buildCommand(ArgResults args) async {
  RandomAccessFile? lock;
  try {
    require(args.rest.length == 1 && args.rest.single == 'android',
        'USAGE_ERROR', 'Use build android.');
    require(args['strategy'] == 'bytecode', 'BUILD_STRATEGY_UNSUPPORTED',
        'build supports --strategy bytecode only; so patches keep using the v1 workflow.');
    final host = requireSupportedHost();
    String required(String key) {
      final value = args[key] as String?;
      require(value != null && value.isNotEmpty, 'BUILD_CONFIG_INVALID',
          'Missing --$key');
      return value!;
    }

    final cache = managedCache(args['cache-dir'] as String?);
    await rejectLinks(cache);
    await Directory(cache).create(recursive: true);
    final commands = Commands(cache);
    final project =
        p.absolute(args['project'] as String? ?? Directory.current.path);
    final key = (await File(required('public-key')).readAsString()).trim();
    final request = BuildRequest(
        project: project,
        output: p.absolute(args['out'] as String? ??
            p.join(project, '.dart_tool/flutter_patcher/releases',
                DateTime.now().microsecondsSinceEpoch.toString())),
        publicKey: key,
        hostPolicy: args['host-policy'] == null
            ? null
            : HostPolicy.parse(
                await File(args['host-policy'] as String).readAsString()),
        target: args['target'] as String,
        flavor: args['flavor'] as String?,
        versionCode: args['version-code'] as String?,
        frameworkReuse: args['framework-reuse'] == true);
    await request.validate();
    final offline = args['offline'] == true;
    require(!(offline && args['refresh-tools'] == true), 'CONFIG_INVALID',
        'Cannot refresh tools offline.');
    final baselineStore = BaselineStore.open(
        Uri.parse(required('baseline-store')), commands,
        offline: offline);
    await baselineStore.probe();
    final android = locateAndroidSdk(host);
    require(android != null, 'ANDROID_SDK_MISSING',
        'Set ANDROID_HOME to an initialized Android SDK.');
    checkJavaHome(host);
    final aapt = await selectAapt(android!, host);
    await rejectLinks(p.join(cache, 'doctor.lock'));
    lock = await File(p.join(cache, 'doctor.lock')).open(mode: FileMode.append);
    await lock.lock(FileLock.blockingExclusive);
    final sdk = await identify(
        await Directory(findFlutter(args['flutter-sdk'] as String?))
            .resolveSymbolicLinks(),
        commands);
    require(sdk.root != p.join(cache, 'flutter', sdk.version), 'CONFIG_INVALID',
        'Select the stock Flutter SDK.');
    final artifacts = ArtifactStore(
        cache,
        Uri.parse(args['artifacts-url'] as String),
        Uri.parse(args['supported-versions-url'] as String),
        Downloads(offline: offline));
    await artifacts.checkSupport(sdk.version);
    final engine = await artifacts.obtain('engine', sdk);
    await artifacts.obtain('tools', sdk,
        refresh: args['refresh-tools'] == true);
    final environment = EnvironmentBuilder(cache, commands, offline: offline);
    final managed = await environment.prepare(sdk, artifacts, engine);
    final result = await BuildPipeline(
            commands,
            sdk,
            managed,
            artifacts.file(
                sdk, 'tools', 'flutter_patcher_tools-${sdk.version}.dill'),
            cache,
            aapt,
            engine,
            BaselineRepository(p.join(cache, 'baselines'), baselineStore))
        .build(request);
    stdout.writeln(jsonEncode({'command': 'build', ...result}));
    return 0;
  } catch (error) {
    final failure = error is Failure
        ? error
        : Failure('BUILD_FAILED', 'Build failed (${error.runtimeType}).');
    stderr.writeln(jsonEncode({
      'command': 'build',
      'status': 'failed',
      'code': failure.code,
      'message': failure.message
    }));
    return 2;
  } finally {
    if (lock != null) {
      await lock.unlock();
      await lock.close();
    }
  }
}
