import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';
import '../core.dart';
import '../sdk/artifacts.dart';
import '../sdk/environment.dart';
import '../sdk/package_inputs.dart';
import '../baseline/manifest.dart';
import '../baseline/repository.dart';
import 'workspace.dart';
import 'bootstrap.dart';
import 'runtime_package.dart';
import 'outputs.dart';
import 'host_policy.dart';
import 'dart:convert';

class BuildRequest {
  final String project, output, publicKey;
  final String target;
  final String? flavor, versionCode;
  final HostPolicy? hostPolicy;

  /// Internal integration harness only; deliberately not a CLI option.
  final bool pipelineValidationOnly;

  /// WP-2.5 host reuse surface. Off produces the pre-partition schema so the
  /// same source can be measured with and without the surface.
  final bool frameworkReuse;
  BuildRequest(
      {required this.project,
      required this.output,
      required this.publicKey,
      this.target = 'lib/main.dart',
      this.flavor,
      this.versionCode,
      this.hostPolicy,
      this.pipelineValidationOnly = false,
      this.frameworkReuse = true});
  Future<void> validate() async {
    require(
        target.startsWith('lib/') &&
            !target.split('/').contains('..') &&
            !target.contains('\\') &&
            await File(p.join(project, target)).exists(),
        'BUILD_CONFIG_INVALID',
        'Target must be a Dart entry under lib/.');
    require(flavor == null || RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(flavor!),
        'BUILD_CONFIG_INVALID', 'Invalid flavor.');
    require(versionCode == null || RegExp(r'^[0-9]+$').hasMatch(versionCode!),
        'BUILD_CONFIG_INVALID', 'Invalid versionCode.');
    bootstrapSource('app', 'main.dart', '0' * 64, publicKey);
    if (hostPolicy != null) {
      require(
          !pipelineValidationOnly &&
              hostPolicy!.fields['fptc_key'] == publicKey &&
              hostPolicy!.fields['flavor'] == (flavor ?? 'default') &&
              (versionCode == null ||
                  hostPolicy!.fields['version_code'] == versionCode),
          'BUILD_CONFIG_INVALID',
          'Host policy differs from build inputs.');
    }
    await rejectLinks(output);
    require(
        !await FileSystemEntity.isDirectory(output) &&
            !await File(output).exists(),
        'BUILD_CONFIG_INVALID',
        'Use a new output directory.');
  }
}

class BuildPipeline {
  final Commands commands;
  final SdkIdentity sdk;
  final String managed, tool, cache, aapt;
  final Map<String, dynamic> engine;
  final BaselineRepository baselines;
  final EnvironmentBuilder environment;
  BuildPipeline(this.commands, this.sdk, this.managed, this.tool, this.cache,
      this.aapt, this.engine, this.baselines)
      : environment = EnvironmentBuilder(cache, commands);

  Future<Map<String, dynamic>> build(BuildRequest request) async {
    await request.validate();
    require(
        !p.equals(p.absolute(request.output), p.absolute(sdk.root)) &&
            !p.isWithin(p.absolute(sdk.root), p.absolute(request.output)),
        'BUILD_CONFIG_INVALID',
        'Output cannot be inside the selected SDK.');
    final work = temporaryName(p.join(cache, 'builds/run'));
    await rejectLinks(work);
    await Directory(work).create(recursive: true);
    require(!work.contains(',') && !work.contains('\n'), 'BUILD_CONFIG_INVALID',
        'Build paths cannot contain commas/newlines.');
    final workspace = BuildWorkspace(work);
    var phase = 'prepare';
    var commandIndex = 0;
    Future<String> run(String executable, List<String> args,
        {String? cwd, Map<String, String>? env}) async {
      final result = await commands.runResult(executable, args,
          cwd: cwd,
          extraEnvironment: env,
          timeout: const Duration(minutes: 30));
      await File(p.join(work, '${commandIndex++}-$phase.log'))
          .writeAsString('${result.stdout}\n${result.stderr}');
      require(result.exitCode == 0, 'BUILD_STEP_FAILED',
          '$phase failed (exit ${result.exitCode}); evidence: $work');
      return result.stdout;
    }

    Future<void> call(List<String> args) async {
      await run(sdk.dart, [tool, ...args]);
    }

    try {
      final usage = await run(sdk.dart, [tool, '--help']);
      require(
          [
            'inspect-build',
            'compile-baseline',
            'extract-surface',
            'merge-interface',
            '--out-details'
          ].every(usage.contains),
          'TOOLS_VERSION_UNSUPPORTED',
          'CI tools with build inspection are required.');
      final frameworkReuseTool =
          request.frameworkReuse && usage.contains('gen-framework-partition');
      final project =
          await workspace.copyPackage(request.project, application: true);
      final pubspec =
          loadYaml(await File(p.join(project, 'pubspec.yaml')).readAsString())
              as Map;
      final package = pubspec['name'] as String;
      phase = 'pub-get';
      await run(p.join(managed, 'bin/flutter'),
          ['--suppress-analytics', 'pub', 'get', '--enforce-lockfile'],
          cwd: project);
      final packages = p.join(project, '.dart_tool/package_config.json');
      if (!request.pipelineValidationOnly) {
        final config = await readObject(packages);
        final plugins = (config['packages'] as List)
            .where((r) => r['name'] == 'flutter_patcher');
        require(plugins.length == 1, 'BUILD_BOOTSTRAP_UNAVAILABLE',
            'WP-8 flutter_patcher bootstrap dependency is required.');
        final pluginRoot = File(packages)
            .uri
            .resolve(plugins.single['rootUri'] as String)
            .toFilePath();
        require(
            await File(p.join(pluginRoot, 'lib/src/patch_bootstrap.dart'))
                .exists(),
            'BUILD_BOOTSTRAP_UNAVAILABLE',
            'WP-8 PatchBootstrap is not implemented; formal release build is unavailable.');
        await installRuntimePackage(
            packages, package, request.target.substring(4));
      }
      final platform = environment.sdkInput(sdk, managed,
          'bin/cache/artifacts/engine/common/flutter_patched_sdk_product/platform_strong.dill');
      final frontend = environment.sdkInput(sdk, managed,
          'bin/cache/artifacts/engine/linux-x64/frontend_server_aot.dart.snapshot');
      final baseline = p.join(work, 'baseline');
      await Directory(baseline).create();
      final analysis = p.join(work, 'analysis.dill');
      final entry = request.pipelineValidationOnly
          ? 'package:$package/${request.target.substring(4)}'
          : 'package:dynamic_modules/host.dart';
      Future<void> compile(String output,
          {String? iface, String? dump, bool linked = false}) async {
        if (!linked) {
          await run(
              sdk.dart,
              [
                tool,
                'compile-baseline',
                '--platform',
                platform,
                '--target',
                'flutter',
                '--no-aot',
                '--no-tfa',
                '--no-link-platform',
                '--packages',
                packages,
                if (iface != null) ...['--dynamic-interface', iface],
                if (dump != null) ...[
                  '--dump-detailed-dynamic-interface',
                  dump
                ],
                '--output',
                output,
                entry
              ],
              cwd: project);
          return;
        }
        await run(
            p.join(sdk.root, 'bin/cache/dart-sdk/bin/dartaotruntime'),
            [
              frontend,
              '--sdk-root',
              '${p.dirname(platform)}/',
              '--target',
              'flutter',
              '--no-aot',
              '--no-tfa',
              linked ? '--link-platform' : '--no-link-platform',
              '--packages',
              packages,
              if (iface != null) ...['--dynamic-interface', iface],
              if (dump != null) ...['--dump-detailed-dynamic-interface', dump],
              '--output-dill',
              output,
              entry
            ],
            cwd: project);
      }

      phase = 'analysis';
      await compile(analysis, linked: true);
      final refs = p.join(work, 'referenced.yaml'),
          trimRefs = p.join(work, 'referenced-trim.yaml'),
          protocol = p.join(work, 'protocol.yaml');
      await call([
        'extract-surface',
        '--dill',
        analysis,
        '--own',
        package,
        '--out-iface',
        refs,
        '--out-trim-iface',
        trimRefs
      ]);
      await call(
          ['gen-protocol-interface', '--dill', analysis, '--out', protocol]);
      final iface = p.join(baseline, 'dynamic_interface.yaml');
      phase = 'interface';
      final privates = p.join(work, 'platform-privates.yaml');
      final frameworkPartition = p.join(work, 'framework-partition.json');
      if (!request.pipelineValidationOnly) {
        await call([
          'gen-platform-privates',
          '--platform',
          platform,
          '--out',
          privates
        ]);
        if (frameworkReuseTool) {
          await call([
            'gen-framework-partition',
            '--platform',
            platform,
            '--dill',
            analysis,
            '--flutter-version',
            sdk.version,
            '--out',
            frameworkPartition
          ]);
        }
      }
      await call([
        'merge-interface',
        '--dill',
        analysis,
        '--iface',
        refs,
        '--trim-iface',
        trimRefs,
        '--protocol',
        protocol,
        '--mode',
        request.pipelineValidationOnly ? 'lean' : 'whole',
        if (!request.pipelineValidationOnly) ...[
          '--platform-privates',
          privates
        ],
        if (frameworkReuseTool && !request.pipelineValidationOnly) ...[
          '--framework-reuse',
          frameworkPartition
        ],
        '--out-iface',
        iface,
        '--out-trim-iface',
        p.join(work, 'trim_interface.yaml'),
        '--out-details',
        p.join(baseline, 'interface_detailed.json')
      ]);
      await validateDetails(baseline, await hashFile(iface));
      phase = 'baseline-kernel';
      await compile(p.join(baseline, 'app.dill'),
          iface: iface, dump: p.join(baseline, 'compiler_interface.json'));
      await call([
        'inspect-build',
        '--dill',
        p.join(baseline, 'app.dill'),
        '--packages',
        packages,
        '--out',
        baseline,
        '--compiler-interface',
        p.join(baseline, 'compiler_interface.json')
      ]);
      if (frameworkReuseTool && !request.pipelineValidationOnly) {
        await File(frameworkPartition)
            .copy(p.join(baseline, 'framework_partition.json'));
      }
      final partitionHash =
          frameworkReuseTool && !request.pipelineValidationOnly
              ? await hashFile(p.join(baseline, 'framework_partition.json'))
              : null;
      final identity = fingerprint(await hashFile(p.join(baseline, 'app.dill')),
          sdk.engine, await hashFile(iface), sdk.version,
          hostPolicyHash: request.hostPolicy?.digest,
          frameworkPartitionHash: partitionHash);
      // Capture user/plugin sources before injecting generated native policy.
      // The latter has its own fingerprint/APK binding, not a source-file input
      // that the unchanged application must reproduce when preparing a patch.
      final sourceInputs = await packageInputs(packages, application: package);
      String? hostTrust;
      if (request.hostPolicy != null) {
        final policy = request.hostPolicy!;
        await File(p.join(baseline, 'host_policy.json'))
            .writeAsString(policy.canonical);
        final nativeAsset = File(p.join(project,
            'android/app/src/main/assets/flutter_patcher/host-trust.json'));
        require(!await nativeAsset.exists(), 'BUILD_CONFIG_INVALID',
            'Host trust asset is reserved for generated build inputs.');
        await nativeAsset.parent.create(recursive: true);
        hostTrust = jsonEncode({
          'policy': policy.canonical,
          'fingerprint': identity,
          'policy_sha256': policy.digest,
        });
        await nativeAsset.writeAsString(hostTrust);
      }
      final target = p.join(project, '.dart_tool/flutter_patcher/main.dart');
      if (!request.pipelineValidationOnly) {
        await File(target).parent.create(recursive: true);
        await File(target).writeAsString(bootstrapSource(
            package, request.target.substring(4), identity, request.publicKey));
      }
      phase = 'apk';
      final gradle = p.join(cache, 'gradle');
      await Directory(gradle).create(recursive: true);
      await retireFlutterGradleCache(gradle);
      final trace = p.join(work, 'precompiler-trace.json'),
          hostDump = p.join(work, 'host_compiler_interface.json');
      final mirror =
          p.join(cache, 'mirrors', sdk.version, engine['build_id'] as String);
      await run(
          p.join(managed, 'bin/flutter'),
          [
            '--suppress-analytics',
            'build',
            'apk',
            '--release',
            '--no-pub',
            '--target-platform',
            'android-arm64',
            '--target',
            request.pipelineValidationOnly ? request.target : target,
            if (request.flavor != null) ...['--flavor', request.flavor!],
            if (request.versionCode != null) ...[
              '--build-number',
              request.versionCode!
            ],
            '--extra-front-end-options=--dynamic-interface=$iface,--dump-detailed-dynamic-interface=$hostDump',
            '--extra-gen-snapshot-options=--trace-precompiler-to=$trace'
          ],
          cwd: project,
          env: {
            'FLUTTER_STORAGE_BASE_URL': Uri.directory(mirror).toString(),
            'GRADLE_USER_HOME': gradle
          });
      final apk = p.join(project,
          'build/app/outputs/flutter-apk/app-${request.flavor == null ? '' : '${request.flavor}-'}release.apk');
      phase = 'verify-apk';
      final apkInfo = await verifyBuildApk(
          apk, baseline, aapt, commands, engine,
          expectedHostTrust: hostTrust);
      if (request.hostPolicy != null) {
        require(
            apkInfo['application_id'] ==
                    request.hostPolicy!.fields['application_id'] &&
                apkInfo['version_code'] ==
                    request.hostPolicy!.fields['version_code'],
            'BUILD_APK_INVALID',
            'Actual APK differs from immutable host policy.');
      }
      if (request.versionCode != null) {
        require(apkInfo['version_code'] == request.versionCode,
            'BUILD_APK_INVALID', 'Actual versionCode differs.');
      }
      await call([
        'inspect-build',
        '--dill',
        p.join(baseline, 'app.dill'),
        '--packages',
        packages,
        '--out',
        baseline,
        '--trace',
        trace,
        '--compiler-interface',
        hostDump
      ]);
      final kernel = await readObject(p.join(baseline, 'kernel_receipt.json'));
      // Preserve the actual host compiler's authoritative expanded interface.
      await File(hostDump).copy(p.join(baseline, 'compiler_interface.json'));
      await File(packages).copy(p.join(baseline, 'package_config.json'));
      final receipt = <String, dynamic>{
        ...apkInfo,
        ...kernel,
        'schema': 1,
        if (request.hostPolicy != null)
          'host_policy_sha256': request.hostPolicy!.digest,
        if (partitionHash != null) 'framework_partition_sha256': partitionHash,
        'runtime_bootstrap': !request.pipelineValidationOnly,
        'interface_sha256': await hashFile(iface),
        'fingerprint': identity,
        'public_key': request.pipelineValidationOnly ? null : request.publicKey,
        'package_inputs': sourceInputs
      };
      await writeObject(p.join(baseline, 'build_receipt.json'), receipt);
      await workspace.verifyOriginals();
      final metadata = <String, dynamic>{
        'schema':
            partitionHash != null ? 4 : (request.hostPolicy == null ? 2 : 3),
        if (request.hostPolicy != null)
          'host_policy_sha256': request.hostPolicy!.digest,
        if (partitionHash != null) 'framework_partition_sha256': partitionHash,
        'flutter_version': sdk.version,
        'engine_commit': sdk.engine,
        'build_id': engine['build_id'],
        'runtime_bootstrap': !request.pipelineValidationOnly,
        'platform': {
          'path':
              'bin/cache/artifacts/engine/common/flutter_patched_sdk_product/platform_strong.dill',
          'sha256': await hashFile(platform)
        }
      };
      phase = 'archive';
      final archived = await baselines.save(baseline, metadata,
          flavor: request.flavor ?? 'default',
          versionCode: apkInfo['version_code'] as String);
      require(archived['fingerprint'] == identity,
          'BASELINE_FINGERPRINT_MISMATCH', 'Archived fingerprint changed.');
      phase = 'publish-output';
      final report = <String, dynamic>{
        'status': request.pipelineValidationOnly
            ? 'build_pipeline_validated'
            : 'build_archived',
        ...receipt,
        'baseline': archived,
        'work': work,
        'device_verified': false
      };
      final staging = temporaryName(p.absolute(request.output));
      await Directory(staging).create(recursive: true);
      await File(apk).copy(p.join(
          staging,
          request.pipelineValidationOnly
              ? 'validation.apk'
              : 'app-release.apk'));
      await writeObject(p.join(staging, 'build.json'), report);
      require(!await Directory(request.output).exists(), 'BUILD_CONFIG_INVALID',
          'Output appeared during build.');
      await Directory(staging).rename(p.absolute(request.output));
      return {...report, 'output': p.absolute(request.output)};
    } catch (error) {
      await writeObject(p.join(work, 'failure.json'), {
        'phase': phase,
        'error': error is Failure ? error.code : error.runtimeType.toString()
      });
      rethrow;
    }
  }
}
