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
import 'line_endings.dart';
import 'bootstrap.dart';
import 'runtime_package.dart';
import 'outputs.dart';
import 'host_policy.dart';
import 'virtual_paths.dart';
import 'dart:convert';

class BuildRequest {
  final String project, output, publicKey;
  final String target;
  final String? flavor, versionCode;
  final HostPolicy? hostPolicy;

  /// Internal integration harness only; deliberately not a CLI option.
  final bool pipelineValidationOnly;

  BuildRequest(
      {required this.project,
      required this.output,
      required this.publicKey,
      this.target = 'lib/main.dart',
      this.flavor,
      this.versionCode,
      this.hostPolicy,
      this.pipelineValidationOnly = false});
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
    _requireOutsideSdk(request.output);
    final work = temporaryName(p.join(cache, 'builds/run'));
    await rejectLinks(work);
    await Directory(work).create(recursive: true);
    require(!work.contains(',') && !work.contains('\n'), 'BUILD_CONFIG_INVALID',
        'Build paths cannot contain commas/newlines.');
    final workspace = BuildWorkspace(work);
    var phase = 'prepare';
    final run = _runner(work, () => phase);

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
      // Older tools cannot read back virtual source URIs; they keep the
      // path-dependent baseline kernel.
      final virtualTool = usage.contains('--filesystem-root');
      VirtualPackages? virtual;
      final project =
          await workspace.copyPackage(request.project, application: true);
      final crlf = await crlfDartSources(project);
      if (crlf.isNotEmpty) stderr.writeln('WARNING: ${crlfWarning(crlf)}');
      final pubspec =
          loadYaml(await File(p.join(project, 'pubspec.yaml')).readAsString())
              as Map;
      final package = pubspec['name'] as String;
      phase = 'pub-get';
      await run(sdk.host.flutterLauncher(managed),
          ['--suppress-analytics', 'pub', 'get', '--enforce-lockfile'],
          cwd: project);
      final packages = p.join(project, '.dart_tool/package_config.json');
      if (!request.pipelineValidationOnly) {
        final config = await readObject(packages);
        final plugins = (config['packages'] as List)
            .where((r) => r['name'] == 'flutter_patcher');
        require(plugins.length == 1, 'BUILD_BOOTSTRAP_UNAVAILABLE',
            'The application must depend on flutter_patcher to build a bytecode release.');
        final pluginRoot = File(packages)
            .uri
            .resolve(plugins.single['rootUri'] as String)
            .toFilePath();
        require(
            await File(p.join(pluginRoot, 'lib/src/patch_bootstrap.dart'))
                .exists(),
            'BUILD_BOOTSTRAP_UNAVAILABLE',
            'The flutter_patcher dependency has no PatchBootstrap; use a version with bytecode support.');
        await installRuntimePackage(
            packages, package, request.target.substring(4));
      }
      final platform = environment.sdkInput(sdk, managed,
          'bin/cache/artifacts/engine/common/flutter_patched_sdk_product/platform_strong.dill');
      final frontend = environment.sdkInput(sdk, managed,
          sdk.host.toolchain('frontend_server_aot.dart.snapshot'));
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
                if (virtual != null) ...virtual.compilerArgs,
                '--packages',
                virtual?.packagesUri ?? packages,
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
            sdk.dartAotRuntime,
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
      if (!request.pipelineValidationOnly) {
        await call([
          'gen-platform-privates',
          '--platform',
          platform,
          '--out',
          privates
        ]);
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
        '--out-iface',
        iface,
        '--out-trim-iface',
        p.join(work, 'trim_interface.yaml'),
        '--out-details',
        p.join(baseline, 'interface_detailed.json')
      ]);
      await validateDetails(baseline, await hashFile(iface));
      phase = 'baseline-kernel';
      if (virtualTool) {
        virtual = await VirtualPackages.write(
            packages, [p.absolute(work), p.absolute(cache)]);
      }
      await compile(p.join(baseline, 'app.dill'),
          iface: iface, dump: p.join(baseline, 'compiler_interface.json'));
      await call([
        'inspect-build',
        if (virtual != null) ...virtual.compilerArgs,
        '--dill',
        p.join(baseline, 'app.dill'),
        '--packages',
        packages,
        '--out',
        baseline,
        '--compiler-interface',
        p.join(baseline, 'compiler_interface.json')
      ]);
      final identity = fingerprint(await hashFile(p.join(baseline, 'app.dill')),
          sdk.engine, await hashFile(iface), sdk.version,
          hostPolicyHash: request.hostPolicy?.digest);
      // Capture user/plugin sources before injecting generated native policy.
      // The latter has its own fingerprint/APK binding, not a source-file input
      // that the unchanged application must reproduce when preparing a patch.
      final sourceInputs = await packageInputs(packages, application: package);
      final hostTrust = request.hostPolicy == null
          ? null
          : await _writeHostTrust(project, baseline, request.hostPolicy!, identity);
      // Inside the runtime package the entry compiles as a package: URI; a
      // file URI would embed this run's work path in libapp.so.
      final target =
          p.join(project, '.dart_tool/flutter_patcher/runtime/lib/main.dart');
      if (!request.pipelineValidationOnly) {
        await File(target).parent.create(recursive: true);
        await File(target).writeAsString(bootstrapSource(
            package, request.target.substring(4), identity, request.publicKey));
      }
      phase = 'apk';
      final trace = p.join(work, 'precompiler-trace.json'),
          hostDump = p.join(work, 'host_compiler_interface.json');
      final apk = await _assembleApk(run, project, request,
          request.pipelineValidationOnly ? request.target : target, [
        '--extra-front-end-options=--dynamic-interface=$iface,--dump-detailed-dynamic-interface=$hostDump',
        '--extra-gen-snapshot-options=--trace-precompiler-to=$trace'
      ]);
      phase = 'verify-apk';
      final apkInfo = await _verifyApk(apk, baseline, request, hostTrust);
      await call([
        'inspect-build',
        if (virtual != null) ...virtual.compilerArgs,
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
      // Patches read only package names from it; the virtual copy keeps
      // per-run work paths out of the archived baseline.
      await File(virtual?.path ?? packages)
          .copy(p.join(baseline, 'package_config.json'));
      final receipt = <String, dynamic>{
        ...apkInfo,
        ...kernel,
        'schema': 1,
        if (request.hostPolicy != null)
          'host_policy_sha256': request.hostPolicy!.digest,
        'runtime_bootstrap': !request.pipelineValidationOnly,
        'interface_sha256': await hashFile(iface),
        'fingerprint': identity,
        'public_key': request.pipelineValidationOnly ? null : request.publicKey,
        'package_inputs': sourceInputs,
        'build_host': {'os': sdk.host.os, 'arch': sdk.host.arch},
        'crlf_dart_sources': crlf
      };
      await writeObject(p.join(baseline, 'build_receipt.json'), receipt);
      await workspace.verifyOriginals();
      final metadata = <String, dynamic>{
        'schema': request.hostPolicy == null ? 2 : 3,
        if (request.hostPolicy != null)
          'host_policy_sha256': request.hostPolicy!.digest,
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
      await _writeOutput(request, apk, report,
          request.pipelineValidationOnly ? 'validation.apk' : 'app-release.apk');
      return {...report, 'output': p.absolute(request.output)};
    } catch (error) {
      await _recordFailure(work, phase, error);
      rethrow;
    }
  }

  /// SO host: the app's own entry built with the managed engine and its host
  /// policy packaged, archived as one release object. No kernel or interface.
  Future<Map<String, dynamic>> buildSo(BuildRequest request) async {
    await request.validate();
    final policy = request.hostPolicy!;
    require(policy.fields['strategy'] == 'so', 'BUILD_CONFIG_INVALID',
        'Host policy strategy is not so.');
    _requireOutsideSdk(request.output);
    final work = temporaryName(p.join(cache, 'builds/run'));
    await rejectLinks(work);
    await Directory(work).create(recursive: true);
    final workspace = BuildWorkspace(work);
    var phase = 'prepare';
    final run = _runner(work, () => phase);
    try {
      final project =
          await workspace.copyPackage(request.project, application: true);
      final package = (loadYaml(
              await File(p.join(project, 'pubspec.yaml')).readAsString())
          as Map)['name'] as String;
      phase = 'pub-get';
      await run(sdk.host.flutterLauncher(managed),
          ['--suppress-analytics', 'pub', 'get', '--enforce-lockfile'],
          cwd: project);
      final packages = p.join(project, '.dart_tool/package_config.json');
      require(
          ((await readObject(packages))['packages'] as List)
              .any((r) => r['name'] == 'flutter_patcher'),
          'BUILD_BOOTSTRAP_UNAVAILABLE',
          'The application must depend on flutter_patcher to build an SO release.');
      final release = p.join(work, 'release');
      await Directory(release).create();
      final identity = soFingerprint(
          sdk.version, sdk.engine, engine['build_id'] as String, policy.digest);
      final sourceInputs = await packageInputs(packages, application: package);
      final hostTrust =
          await _writeHostTrust(project, release, policy, identity);
      phase = 'apk';
      final apk = await _assembleApk(run, project, request, request.target, const []);
      phase = 'verify-apk';
      final apkInfo = await _verifyApk(apk, release, request, hostTrust);
      final virtual = await VirtualPackages.write(
          packages, [p.absolute(work), p.absolute(cache)]);
      await File(virtual.path).copy(p.join(release, 'package_config.json'));
      final receipt = <String, dynamic>{
        ...apkInfo,
        'public_key': request.publicKey,
        'package_inputs': sourceInputs,
        'build_host': {'os': sdk.host.os, 'arch': sdk.host.arch},
        'crlf_dart_sources': const <String>[],
      };
      await workspace.verifyOriginals();
      phase = 'archive';
      final archived = await baselines.saveSo(release, receipt, policy,
          flutterVersion: sdk.version,
          engineCommit: sdk.engine,
          buildId: engine['build_id'] as String);
      require(archived['fingerprint'] == identity,
          'BASELINE_FINGERPRINT_MISMATCH', 'Archived fingerprint changed.');
      phase = 'publish-output';
      final report = <String, dynamic>{
        'status': 'build_archived',
        'strategy': 'so',
        ...receipt,
        'fingerprint': identity,
        'baseline': archived,
        'work': work,
        'device_verified': false
      };
      await _writeOutput(request, apk, report, 'app-release.apk');
      return {...report, 'output': p.absolute(request.output)};
    } catch (error) {
      await _recordFailure(work, phase, error);
      rethrow;
    }
  }

  void _requireOutsideSdk(String output) => require(
      !p.equals(p.absolute(output), p.absolute(sdk.root)) &&
          !p.isWithin(p.absolute(sdk.root), p.absolute(output)),
      'BUILD_CONFIG_INVALID',
      'Output cannot be inside the selected SDK.');

  /// Runs one build step, logged under [work] as `<n>-<phase>.log`.
  _Run _runner(String work, String Function() phase) {
    var index = 0;
    return (executable, args, {cwd, env}) async {
      final result = await commands.runResult(executable, args,
          cwd: cwd, extraEnvironment: env, timeout: const Duration(minutes: 30));
      await File(p.join(work, '${index++}-${phase()}.log'))
          .writeAsString('${result.stdout}\n${result.stderr}');
      require(result.exitCode == 0, 'BUILD_STEP_FAILED',
          '${phase()} failed (exit ${result.exitCode}); evidence: $work');
      return result.stdout;
    };
  }

  /// Writes host_policy.json into [policyDir] and the packaged host trust
  /// asset into [project]; returns the asset text.
  Future<String> _writeHostTrust(String project, String policyDir,
      HostPolicy policy, String identity) async {
    await File(p.join(policyDir, 'host_policy.json'))
        .writeAsString(policy.canonical);
    final asset = File(p.join(
        project, 'android/app/src/main/assets/flutter_patcher/host-trust.json'));
    require(!await asset.exists(), 'BUILD_CONFIG_INVALID',
        'Host trust asset is reserved for generated build inputs.');
    await asset.parent.create(recursive: true);
    final text = jsonEncode({
      'policy': policy.canonical,
      'fingerprint': identity,
      'policy_sha256': policy.digest,
    });
    await asset.writeAsString(text);
    return text;
  }

  /// `flutter build apk` with the managed engine mirror; returns the APK path.
  Future<String> _assembleApk(_Run run, String project, BuildRequest request,
      String target, List<String> extra) async {
    final gradle = p.join(cache, 'gradle');
    await Directory(gradle).create(recursive: true);
    await retireFlutterGradleCache(gradle);
    final mirror =
        p.join(cache, 'mirrors', sdk.version, engine['build_id'] as String);
    await run(
        sdk.host.flutterLauncher(managed),
        [
          '--suppress-analytics',
          'build',
          'apk',
          '--release',
          '--no-pub',
          '--target-platform',
          'android-arm64',
          '--target',
          target,
          if (request.flavor != null) ...['--flavor', request.flavor!],
          if (request.versionCode != null) ...[
            '--build-number',
            request.versionCode!
          ],
          ...extra
        ],
        cwd: project,
        env: {
          'FLUTTER_STORAGE_BASE_URL': Uri.directory(mirror).toString(),
          'GRADLE_USER_HOME': gradle
        });
    return p.join(project,
        'build/app/outputs/flutter-apk/app-${request.flavor == null ? '' : '${request.flavor}-'}release.apk');
  }

  /// Verifies the APK, extracts libapp.so into [dir] and binds it to the request.
  Future<Map<String, dynamic>> _verifyApk(String apk, String dir,
      BuildRequest request, String? hostTrust) async {
    final apkInfo = await verifyBuildApk(apk, dir, aapt, commands, engine,
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
    return apkInfo;
  }

  Future<void> _writeOutput(BuildRequest request, String apk,
      Map<String, dynamic> report, String name) async {
    final staging = temporaryName(p.absolute(request.output));
    await Directory(staging).create(recursive: true);
    await File(apk).copy(p.join(staging, name));
    await writeObject(p.join(staging, 'build.json'), report);
    require(!await Directory(request.output).exists(), 'BUILD_CONFIG_INVALID',
        'Output appeared during build.');
    await Directory(staging).renameRetry(p.absolute(request.output));
  }

  Future<void> _recordFailure(String work, String phase, Object error) =>
      writeObject(p.join(work, 'failure.json'), {
        'phase': phase,
        'error': error is Failure ? error.code : error.runtimeType.toString()
      });
}

typedef _Run = Future<String> Function(String executable, List<String> args,
    {String? cwd, Map<String, String>? env});
