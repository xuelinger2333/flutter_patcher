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
import '../project.dart';

Future<int> buildCommand(ArgResults args) async {
  RandomAccessFile? lock;
  try {
    require(
      args.rest.length == 1 &&
          const ['android', 'ios'].contains(args.rest.single),
      'USAGE_ERROR',
      'Use build android or build ios.',
    );
    final platform = args.rest.single;

    final host = requireSupportedHost(target: platform);

    final cache = managedCache(args['cache-dir'] as String?);
    await rejectLinks(cache);
    await Directory(cache).create(recursive: true);
    final commands = Commands(cache);
    final project = p.absolute(
      args['project'] as String? ?? Directory.current.path,
    );
    final config = await ProjectConfig.load(project);
    final policy = args['host-policy'] == null
        ? await HostPolicy.of(
            project,
            config,
            platform: platform,
            applicationId: args['application-id'] as String?,
            versionCode: args['version-code'] as String?,
            flavor: args['flavor'] as String?,
            channel: args['channel'] as String?,
            strategy: args['strategy'] as String?,
          )
        : HostPolicy.read(
            await File(args['host-policy'] as String).readAsString(),
          );
    // The patch public key: what the host verifies envelopes with.
    final key = args['public-key'] == null
        ? policy.fields['fptc_key']!
        : (await File(args['public-key'] as String).readAsString()).trim();
    final request = BuildRequest(
      project: project,
      output: p.absolute(
        args['out'] as String? ??
            p.join(
              project,
              '.dart_tool/flutter_patcher/releases',
              DateTime.now().microsecondsSinceEpoch.toString(),
            ),
      ),
      publicKey: key,
      hostPolicy: policy,
      target: args['target'] as String,
      flavor: args['flavor'] as String?,
      versionCode: args['version-code'] as String?,
      exportMethod: args['export-method'] as String?,
      url: config.url,
    );
    require(
      request.platform == platform,
      'BUILD_CONFIG_INVALID',
      'The host policy ABI is for ${request.platform}; use build ${request.platform}.',
    );
    // Apple ships the iOS toolchain (Xcode, codesign) for macOS only.
    require(
      platform == 'android' || host.os == 'macos',
      'HOST_UNSUPPORTED',
      'build ios requires macOS with Xcode; patch ios runs on every host.',
    );
    await request.validate();
    final offline = args['offline'] == true;
    final baselineUri = Uri.parse(
      args['baseline-store'] as String? ?? config.baselineStore,
    );
    final baselineStore = BaselineStore.open(
      baselineUri,
      commands,
      offline: offline,
    );
    if (args['baseline-store'] == null && config.baselinesInProject) {
      stderr.writeln(
        'WARNING: BASELINE_STORE_LOCAL: this host\'s baseline is '
        'kept only in ${config.baselineStore}; every patch of the host needs '
        'it, so set baseline_store in ${ProjectConfig.file} to a durable store.',
      );
    }
    if (!policy.signed) {
      stderr.writeln(
        'WARNING: UNSIGNED: this host accepts patch files that are not '
        'signed, so whoever can hand the app a file can run code in it. To '
        'sign, run `flutter_patcher keys init` and build again.',
      );
    }
    if (config.urlIsLocal) {
      stderr.writeln(
        'WARNING: URL_LOCAL: this host looks for patches at ${config.url}, '
        'where serve offers them while developing; set url in '
        '${ProjectConfig.file} to your HTTPS address before going live.',
      );
    }
    // build archives a host's first baseline, so a new file store starts here.
    if (baselineUri.scheme == 'file') {
      await rejectLinks(baselineUri.toFilePath());
      await Directory(baselineUri.toFilePath()).create(recursive: true);
    }
    await baselineStore.probe();
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
      'Select the stock Flutter SDK.',
    );
    var aapt = '';
    if (platform == 'android') {
      final android = await resolveAndroidSdk(commands, host, sdk.flutter);
      checkJavaHome(host);
      aapt = await selectAapt(android, host);
    }
    final artifacts = ArtifactStore(
      cache,
      Uri.parse(args['artifacts-url'] as String),
      Uri.parse(args['index-url'] as String),
      Downloads(offline: offline),
    );
    // A new host uses the current releases; its baseline records them.
    await artifacts.selectCurrent(sdk.version);
    final engine = await artifacts.obtain(
      platform == 'ios' ? 'engine-ios' : 'engine',
      sdk,
    );
    await artifacts.obtain('tools', sdk);
    final environment = EnvironmentBuilder(cache, commands, offline: offline);
    final managed = await (platform == 'ios'
        ? environment.prepare(sdk, artifacts, ios: engine)
        : environment.prepare(sdk, artifacts, android: engine));
    final pipeline = BuildPipeline(
      commands,
      sdk,
      managed,
      artifacts.file(sdk, 'tools', 'flutter_patcher_tools-${sdk.version}.dill'),
      cache,
      aapt,
      engine,
      BaselineRepository(p.join(cache, 'baselines'), baselineStore),
      artifacts.selected,
    );
    final result = request.hostPolicy.fields['strategy'] == 'so'
        ? await pipeline.buildSo(request)
        : await pipeline.build(request);
    stdout.writeln(jsonEncode({'command': 'build', ...result}));
    return 0;
  } catch (error) {
    final failure = error is Failure
        ? error
        : unexpectedFailure('BUILD_FAILED', 'Build', error);
    stderr.writeln(
      jsonEncode({
        'command': 'build',
        'status': 'failed',
        'code': failure.code,
        'message': failure.message,
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
