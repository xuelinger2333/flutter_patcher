import 'dart:io';
import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';
import '../core.dart';
import '../baseline/repository.dart';
import '../build/host_policy.dart';
import '../build/pipeline.dart';
import '../build/workspace.dart';
import '../sdk/android.dart';
import '../sdk/package_inputs.dart';
import 'package.dart';
import 'pipeline.dart';
import 'so_package.dart';

extension SoPatch on PatchPipeline {
  /// Rebuilds an SO host's APK from the changed sources with the same engine,
  /// flavor, versionCode and host policy, and signs a v2 patch.zip holding its
  /// libapp.so and the flutter assets that differ from the release.
  Future<Map<String, Object?>> patchSo(
      PatchRequest req, ResolvedRelease resolved, String work) async {
    require(req.assets.isEmpty, 'PATCH_CONFIG_INVALID',
        'SO patches select changed assets themselves.');
    final receipt = resolved.receipt;
    require(
        resolved.compile['flutter_version'] == sdk.version &&
            resolved.compile['engine_commit'] == sdk.engine &&
            resolved.buildId == engine?['build_id'],
        'PATCH_BASELINE_INCOMPATIBLE',
        'SDK or engine build differs from the release');
    require(req.minBuild.toString() == receipt['version_code'],
        'PATCH_BASELINE_INCOMPATIBLE', 'Minimum build must match the target release');
    final key =
        signingKey(req.privateKey, expectedPublic: receipt['public_key'] as String);
    final policy = HostPolicy.parse(
        await File(p.join(resolved.releaseRoot, 'host_policy.json')).readAsString());
    final android = locateAndroidSdk(sdk.host);
    require(android != null, 'ANDROID_SDK_MISSING',
        'Set ANDROID_HOME to an initialized Android SDK.');
    checkJavaHome(sdk.host);
    final builder = BuildPipeline(commands, sdk, managed, tool, cache,
        await selectAapt(android!, sdk.host), engine!, baselines);
    var phase = 'sources';
    final run = builder.runner(work, () => phase);
    final workspace = BuildWorkspace(work);
    final project = await workspace.copyPackage(req.project, application: true);
    await run(
        sdk.host.flutterLauncher(managed),
        [
          '--suppress-analytics',
          'pub',
          'get',
          '--enforce-lockfile',
          if (req.offline) '--offline'
        ],
        cwd: project);
    final app = (loadYaml(
            await File(p.join(project, 'pubspec.yaml')).readAsString()) as Map)['name']
        as String;
    final changed = <String>[];
    nativeInputChanges(
        await packageInputs(p.join(project, '.dart_tool/package_config.json'),
            application: app),
        receipt['package_inputs'] as Map,
        app,
        changed);
    phase = 'apk';
    final request = BuildRequest(
        project: project,
        output: p.join(work, 'unused'),
        publicKey: receipt['public_key'] as String,
        target: req.target,
        flavor: req.flavor == 'default' ? null : req.flavor,
        versionCode: req.minBuild.toString(),
        hostPolicy: policy);
    final host = p.join(work, 'host');
    await Directory(host).create();
    final trust =
        await builder.writeHostTrust(project, host, policy, resolved.fingerprint);
    final apk =
        await builder.assembleApk(run, project, request, req.target, const []);
    phase = 'verify-apk';
    final info = await builder.verifyApk(apk, host, request, trust);
    phase = 'package';
    final libapp = await File(p.join(host, 'libapp.so')).readAsBytes();
    final package = soPackage(
        apk: ZipDecoder().decodeBytes(await File(apk).readAsBytes()),
        libapp: libapp,
        release: receipt['resources'] as Map,
        version: '${req.seq}',
        targetVersionCode: req.minBuild,
        target: resolved.target);
    if (info['libapp_sha256'] != receipt['libapp_sha256']) changed.add('libapp.so');
    changed.addAll(package.changed);
    require(changed.isNotEmpty, 'PATCH_NO_CHANGES',
        'No Dart, dependency or resource changes detected');
    final artifact = await sealPatch(
        payload: package.bytes,
        fingerprint: resolved.fingerprint,
        seq: req.seq,
        key: key,
        work: work);
    await workspace.verifyOriginals();
    await baselines.recheck(resolved, sdkRoot: sdk.root);
    return writeOutput(req, artifact['file'] as String, {
      'status': 'patch_created',
      'platform': 'android',
      'abi': 'arm64-v8a',
      'strategy': 'so',
      'fingerprint': resolved.fingerprint,
      'patch_seq': req.seq,
      'min_build': req.minBuild,
      'changed': changed,
      'sha256': artifact['sha256'],
      'bytes': artifact['bytes'],
      'device_verified': false,
      'release_baseline_verified': true,
      'release': resolved.report,
      'baseline_cache': {'release': resolved.releaseRoot},
      'work': work
    });
  }
}