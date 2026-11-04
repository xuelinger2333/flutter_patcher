import 'dart:io';

import 'package:path/path.dart' as p;

import 'pins.dart';

import 'package:yaml/yaml.dart';

import '../core.dart';
import '../run_work.dart';
import '../sdk/artifacts.dart';
import '../sdk/environment.dart';
import '../sdk/package_inputs.dart';
import '../baseline/manifest.dart';
import '../baseline/repository.dart';
import 'workspace.dart';
import 'line_endings.dart';
import 'bootstrap.dart';
import 'defines.dart';
import 'runtime_package.dart';
import 'outputs.dart';
import 'host_policy.dart';
import 'ios.dart';
import '../publish/protocol.dart';
import 'virtual_paths.dart';

import 'dart:convert';

class BuildRequest {
  final String project, output, publicKey;
  final String target;
  final String? flavor, versionCode, exportMethod;
  final HostPolicy hostPolicy;

  /// `android` or `ios`, from the host policy's ABI.
  String get platform => platformOfAbi[hostPolicy.fields['abi']]!;

  BuildRequest({
    required this.project,
    required this.output,
    required this.publicKey,
    required this.hostPolicy,
    this.target = 'lib/main.dart',
    this.flavor,
    this.versionCode,
    this.exportMethod,
  });
  Future<void> validate() async {
    require(
      target.startsWith('lib/') &&
          !target.split('/').contains('..') &&
          !target.contains('\\') &&
          await File(p.join(project, target)).exists(),
      'BUILD_CONFIG_INVALID',
      'Target must be a Dart entry under lib/.',
    );
    require(
      flavor == null || RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(flavor!),
      'BUILD_CONFIG_INVALID',
      'Invalid flavor.',
    );
    require(
      versionCode == null || RegExp(r'^[0-9]+$').hasMatch(versionCode!),
      'BUILD_CONFIG_INVALID',
      'Invalid versionCode.',
    );
    require(
      exportMethod == null ||
          (platform == 'ios' && iosExportMethods.contains(exportMethod)),
      'BUILD_CONFIG_INVALID',
      '--export-method applies to iOS builds: ${iosExportMethods.join(', ')}.',
    );
    bootstrapSource('app', 'main.dart', '0' * 64, publicKey);
    require(
      hostPolicy.fields['fptc_key'] == publicKey &&
          hostPolicy.fields['flavor'] == (flavor ?? 'default') &&
          (versionCode == null ||
              hostPolicy.fields['version_code'] == versionCode),
      'BUILD_CONFIG_INVALID',
      'Host policy differs from build inputs.',
    );
    await rejectLinks(output);
    require(
      !await FileSystemEntity.isDirectory(output) &&
          !await File(output).exists(),
      'BUILD_CONFIG_INVALID',
      'Use a new output directory.',
    );
  }
}

class BuildPipeline {
  final Commands commands;
  final SdkIdentity sdk;
  final String managed, tool, cache, aapt;
  final Map<String, dynamic> engine;
  final BaselineRepository baselines;
  final EnvironmentBuilder environment;

  /// The artifact releases this host is built with; its release records
  /// them, so every patch of it uses the same ones.
  final Map<String, ArtifactRelease> releases;
  BuildPipeline(
    this.commands,
    this.sdk,
    this.managed,
    this.tool,
    this.cache,
    this.aapt,
    this.engine,
    this.baselines,
    this.releases,
  ) : environment = EnvironmentBuilder(cache, commands);

  /// Release receipt fields naming what the host was built with.
  Map<String, Object?> get _built => {
    'artifacts': {
      for (final release in releases.values) release.kind: release.toJson(),
    },
    // What a patch may rely on at boot.
    'engine_capabilities': engine['capabilities'],
  };

  Future<Map<String, dynamic>> build(BuildRequest request) async {
    await request.validate();
    _requireOutsideSdk(request.output);
    final work = await RunWork.create(p.join(cache, 'builds/run'));
    require(
      !work.contains(',') && !work.contains('\n'),
      'BUILD_CONFIG_INVALID',
      'Build paths cannot contain commas/newlines.',
    );
    final workspace = BuildWorkspace(work);
    var phase = 'prepare';
    final run = runner(work, () => phase);

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
          '--out-details',
        ].every(usage.contains),
        'TOOLS_VERSION_UNSUPPORTED',
        'CI tools with build inspection are required.',
      );
      // Older tools cannot read back virtual source URIs; they keep the
      // path-dependent baseline kernel.
      final virtualTool = usage.contains('--filesystem-root');
      VirtualPackages? virtual;
      final project = await workspace.copyPackage(
        request.project,
        application: true,
      );
      final crlf = await crlfDartSources(project);
      if (crlf.isNotEmpty) {
        stderr.writeln('WARNING: CRLF_DART_SOURCES: ${crlfWarning(crlf)}');
      }
      final pubspec = loadYaml(
        await File(p.join(project, 'pubspec.yaml')).readAsString(),
      ) as Map;
      final package = pubspec['name'] as String;
      phase = 'pub-get';
      await run(sdk.host.flutterLauncher(managed), [
        '--suppress-analytics',
        'pub',
        'get',
        '--enforce-lockfile',
      ], cwd: project);
      final packages = p.join(project, '.dart_tool/package_config.json');
      final config = await readObject(packages);
      // A whole-tier patch carries every free package, so the host interface
      // covers what they use, not only what the application itself does.
      final pins = await computePackagePins(packages, package);
      final plugins = (config['packages'] as List).where(
        (r) => r['name'] == 'flutter_patcher',
      );
      require(
        plugins.length == 1,
        'BUILD_BOOTSTRAP_UNAVAILABLE',
        'The application must depend on flutter_patcher to build a bytecode release.',
      );
      final pluginRoot = File(packages).uri
          .resolve(plugins.single['rootUri'] as String)
          .toFilePath();
      require(
        await File(p.join(pluginRoot, 'lib/src/patch_bootstrap.dart')).exists(),
        'BUILD_BOOTSTRAP_UNAVAILABLE',
        'The flutter_patcher dependency has no PatchBootstrap; use a version with bytecode support.',
      );
      await installRuntimePackage(
        packages,
        package,
        request.target.substring(4),
      );
      final platform = environment.sdkInput(
        sdk,
        managed,
        'bin/cache/artifacts/engine/common/flutter_patched_sdk_product/platform_strong.dill',
      );
      final frontend = environment.sdkInput(
        sdk,
        managed,
        sdk.host.toolchain('frontend_server_aot.dart.snapshot'),
      );
      final baseline = p.join(work, 'baseline');
      await Directory(baseline).create();
      final analysis = p.join(work, 'analysis.dill');
      const entry = 'package:dynamic_modules/host.dart';
      Future<void> compile(
        String output, {
        String? iface,
        String? dump,
        bool linked = false,
      }) async {
        if (!linked) {
          await run(sdk.dart, [
            tool,
            'compile-baseline',
            '--platform',
            platform,
            '--target',
            'flutter',
            '--no-aot',
            '--no-tfa',
            '--no-link-platform',
            ...defineArgs(releaseDefines(request.flavor)),
            if (virtual != null) ...virtual.compilerArgs,
            '--packages',
            virtual?.packagesUri ?? packages,
            if (iface != null) ...['--dynamic-interface', iface],
            if (dump != null) ...['--dump-detailed-dynamic-interface', dump],
            '--output',
            output,
            entry,
          ], cwd: project);
          return;
        }
        await run(sdk.dartAotRuntime, [
          frontend,
          '--sdk-root',
          '${p.dirname(platform)}/',
          '--target',
          'flutter',
          '--no-aot',
          '--no-tfa',
          linked ? '--link-platform' : '--no-link-platform',
          ...defineArgs(releaseDefines(request.flavor)),
          '--packages',
          packages,
          if (iface != null) ...['--dynamic-interface', iface],
          if (dump != null) ...['--dump-detailed-dynamic-interface', dump],
          '--output-dill',
          output,
          entry,
        ], cwd: project);
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
        if (pins.free.isNotEmpty && usage.contains('--scan')) ...[
          '--scan',
          (pins.free.toList()..sort()).join(','),
        ],
        '--out-iface',
        refs,
        '--out-trim-iface',
        trimRefs,
      ]);
      await call([
        'gen-protocol-interface',
        '--dill',
        analysis,
        '--out',
        protocol,
      ]);
      final iface = p.join(baseline, 'dynamic_interface.yaml');
      phase = 'interface';
      final privates = p.join(work, 'platform-privates.yaml');
      await call([
        'gen-platform-privates',
        '--platform',
        platform,
        '--out',
        privates,
      ]);
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
        'whole',
        '--platform-privates',
        privates,
        '--out-iface',
        iface,
        '--out-trim-iface',
        p.join(work, 'trim_interface.yaml'),
        '--out-details',
        p.join(baseline, 'interface_detailed.json'),
      ]);
      await validateDetails(baseline, await hashFile(iface));
      phase = 'baseline-kernel';
      if (virtualTool) {
        virtual = await VirtualPackages.write(packages, [
          p.absolute(work),
          p.absolute(cache),
        ]);
      }
      await compile(
        p.join(baseline, 'app.dill'),
        iface: iface,
        dump: p.join(baseline, 'compiler_interface.json'),
      );
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
        p.join(baseline, 'compiler_interface.json'),
      ]);
      final identity = fingerprint(
        await hashFile(p.join(baseline, 'app.dill')),
        sdk.engine,
        await hashFile(iface),
        sdk.version,
        hostPolicyHash: request.hostPolicy.digest,
      );
      // Capture user/plugin sources before injecting generated native policy.
      // The latter has its own fingerprint/APK binding, not a source-file input
      // that the unchanged application must reproduce when preparing a patch.
      final sourceInputs = await packageInputs(packages, application: package);
      final hostTrust = await writeHostTrust(
        project,
        baseline,
        request.hostPolicy,
        identity,
      );
      final target = await writeBootstrapEntry(
        project,
        bootstrapSource(
          package,
          request.target.substring(4),
          identity,
          request.publicKey,
        ),
      );
      final ios = request.platform == 'ios';
      phase = ios ? 'ipa' : 'apk';
      final trace = p.join(work, 'precompiler-trace.json'),
          hostDump = p.join(work, 'host_compiler_interface.json');
      final extra = [
        '--extra-front-end-options=--dynamic-interface=$iface,--dump-detailed-dynamic-interface=$hostDump',
        '--extra-gen-snapshot-options=--trace-precompiler-to=$trace',
      ];
      final apk = ios
          ? await assembleIpa(
              run,
              sdk.host.flutterLauncher(managed),
              project,
              request,
              target,
              extra,
            )
          : await assembleApk(run, project, request, target, extra);
      phase = ios ? 'verify-ipa' : 'verify-apk';
      final apkInfo = ios
          ? _bind(
              await verifyBuildIpa(
                commands,
                apk,
                project,
                baseline,
                managed,
                expectedHostTrust: hostTrust,
              ),
              request,
            )
          : await verifyApk(apk, baseline, request, hostTrust);
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
        hostDump,
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
        'host_policy_sha256': request.hostPolicy.digest,
        'runtime_bootstrap': true,
        'interface_sha256': await hashFile(iface),
        'fingerprint': identity,
        'public_key': request.publicKey,
        'package_inputs': sourceInputs,
        'pinned_packages': pins.pinned,
        ..._built,
        'build_host': {'os': sdk.host.os, 'arch': sdk.host.arch},
        'crlf_dart_sources': crlf,
      };
      await writeObject(p.join(baseline, 'build_receipt.json'), receipt);
      await workspace.verifyOriginals();
      final metadata = <String, dynamic>{
        'schema': 3,
        'host_policy_sha256': request.hostPolicy.digest,
        'flutter_version': sdk.version,
        'engine_commit': sdk.engine,
        'build_id': engine['build_id'],
        'runtime_bootstrap': true,
        'platform': {
          'path': 'bin/cache/artifacts/engine/common/flutter_patched_sdk_product/platform_strong.dill',
          'sha256': await hashFile(platform),
        },
      };
      phase = 'archive';
      final archived = await baselines.save(
        baseline,
        metadata,
        flavor: request.flavor ?? 'default',
        versionCode: apkInfo['version_code'] as String,
        abi: request.hostPolicy.fields['abi']!,
      );
      require(
        archived['fingerprint'] == identity,
        'BASELINE_FINGERPRINT_MISMATCH',
        'Archived fingerprint changed.',
      );
      phase = 'publish-output';
      final report = <String, dynamic>{
        'status': 'build_archived',
        ...receipt,
        'baseline': archived,
        'device_verified': false,
      };
      await _writeOutput(
        request,
        apk,
        report,
        ios ? 'app-release.ipa' : 'app-release.apk',
      );
      await RunWork.finish(work);
      return {...report, 'output': p.absolute(request.output)};
    } catch (error) {
      await _recordFailure(work, phase, error);
      rethrow;
    }
  }

  /// SO host: the app built with the managed engine behind the generated
  /// entry that hands a patch's resources to the engine, its host policy
  /// packaged, archived as one release object. No kernel or interface.
  Future<Map<String, dynamic>> buildSo(BuildRequest request) async {
    await request.validate();
    final policy = request.hostPolicy;
    require(
      policy.fields['strategy'] == 'so',
      'BUILD_CONFIG_INVALID',
      'Host policy strategy is not so.',
    );
    _requireOutsideSdk(request.output);
    final work = await RunWork.create(p.join(cache, 'builds/run'));
    final workspace = BuildWorkspace(work);
    var phase = 'prepare';
    final run = runner(work, () => phase);
    try {
      final project = await workspace.copyPackage(
        request.project,
        application: true,
      );
      final crlf = await crlfDartSources(project);
      if (crlf.isNotEmpty) {
        stderr.writeln('WARNING: CRLF_DART_SOURCES: ${crlfWarning(crlf)}');
      }
      final package =
          (loadYaml(await File(p.join(project, 'pubspec.yaml')).readAsString())
                  as Map)['name']
              as String;
      phase = 'pub-get';
      await run(sdk.host.flutterLauncher(managed), [
        '--suppress-analytics',
        'pub',
        'get',
        '--enforce-lockfile',
      ], cwd: project);
      final packages = p.join(project, '.dart_tool/package_config.json');
      require(
        ((await readObject(packages))['packages'] as List).any(
          (r) => r['name'] == 'flutter_patcher',
        ),
        'BUILD_BOOTSTRAP_UNAVAILABLE',
        'The application must depend on flutter_patcher to build an SO release.',
      );
      final release = p.join(work, 'release');
      await Directory(release).create();
      final identity = soFingerprint(
        sdk.version,
        sdk.engine,
        engine['build_id'] as String,
        policy.digest,
      );
      // As for a bytecode host: package inputs include the runtime package,
      // read before the generated entry is written into it.
      await installRuntimePackage(
        packages,
        package,
        request.target.substring(4),
      );
      final sourceInputs = await packageInputs(packages, application: package);
      final hostTrust = await writeHostTrust(
        project,
        release,
        policy,
        identity,
      );
      final target = await writeBootstrapEntry(
        project,
        bootstrapSource(
          package,
          request.target.substring(4),
          identity,
          request.publicKey,
          modules: false,
        ),
      );
      phase = 'apk';
      final apk = await assembleApk(run, project, request, target, const []);
      phase = 'verify-apk';
      final apkInfo = await verifyApk(apk, release, request, hostTrust);
      final virtual = await VirtualPackages.write(packages, [
        p.absolute(work),
        p.absolute(cache),
      ]);
      await File(virtual.path).copy(p.join(release, 'package_config.json'));
      final receipt = <String, dynamic>{
        ...apkInfo,
        'public_key': request.publicKey,
        'package_inputs': sourceInputs,
        ..._built,
        'build_host': {'os': sdk.host.os, 'arch': sdk.host.arch},
        'crlf_dart_sources': crlf,
      };
      await workspace.verifyOriginals();
      phase = 'archive';
      final archived = await baselines.saveSo(
        release,
        receipt,
        policy,
        flutterVersion: sdk.version,
        engineCommit: sdk.engine,
        buildId: engine['build_id'] as String,
      );
      require(
        archived['fingerprint'] == identity,
        'BASELINE_FINGERPRINT_MISMATCH',
        'Archived fingerprint changed.',
      );
      phase = 'publish-output';
      final report = <String, dynamic>{
        'status': 'build_archived',
        'strategy': 'so',
        ...receipt,
        'fingerprint': identity,
        'baseline': archived,
        'device_verified': false,
      };
      await _writeOutput(request, apk, report, 'app-release.apk');
      await RunWork.finish(work);
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
    'Output cannot be inside the selected SDK.',
  );

  /// Runs one build step, logged under [work] as `<n>-<phase>.log`.
  StepRunner runner(String work, String Function() phase) {
    var index = 0;
    return (executable, args, {cwd, env}) async {
      // A real app's first Gradle or Xcode build (dependency downloads) can
      // take far longer than a cached one.
      final result = await commands.runResult(
        executable,
        args,
        cwd: cwd,
        extraEnvironment: env,
        timeout: const Duration(hours: 2),
        logPath: p.join(work, '${index++}-${phase()}.log'),
      );
      if (result.exitCode != 0) {
        throw stepFailure('BUILD_STEP_FAILED', phase(), result, work);
      }
      return result.stdout;
    };
  }

  /// Writes host_policy.json into [policyDir] and the packaged host trust
  /// into the build copy [project] (an APK asset, or an iOS Info.plist key);
  /// returns the trust text.
  Future<String> writeHostTrust(
    String project,
    String policyDir,
    HostPolicy policy,
    String identity,
  ) async {
    await File(p.join(policyDir, 'host_policy.json'))
        .writeAsString(policy.canonical);
    final trust = jsonEncode({
      'policy': policy.canonical,
      'fingerprint': identity,
      'policy_sha256': policy.digest,
    });
    if (platformOfAbi[policy.fields['abi']] == 'ios') {
      await embedIosHostTrust(commands, project, trust);
      return trust;
    }
    final asset = File(
      p.join(
        project,
        'android/app/src/main/assets/flutter_patcher/host-trust.json',
      ),
    );
    require(
      !await asset.exists(),
      'BUILD_CONFIG_INVALID',
      'Host trust asset is reserved for generated build inputs.',
    );
    await asset.parent.create(recursive: true);
    await asset.writeAsString(trust);
    return trust;
  }

  /// `flutter build apk` with the managed engine mirror; returns the APK path.
  Future<String> assembleApk(
    StepRunner run,
    String project,
    BuildRequest request,
    String target,
    List<String> extra,
  ) async {
    final gradle = p.join(cache, 'gradle');
    await Directory(gradle).create(recursive: true);
    await retireFlutterGradleCache(gradle);
    final mirror = p.join(
      cache,
      'mirrors',
      sdk.version,
      engine['build_id'] as String,
    );
    await run(
      sdk.host.flutterLauncher(managed),
      [
        '--suppress-analytics',
        'build',
        'apk',
        '--release',
        // Not --no-pub: only the pub step regenerates the native plugin
        // registrants for release, which leaves out dev_dependency plugins
        // (e.g. integration_test); a stale debug registrant references them
        // and the release compile fails. pub get --enforce-lockfile already
        // ran, so this check resolves nothing.
        '--target-platform',
        'android-arm64',
        '--target',
        target,
        if (request.flavor != null) ...['--flavor', request.flavor!],
        if (request.versionCode != null) ...[
          '--build-number',
          request.versionCode!,
        ],
        ...extra,
      ],
      cwd: project,
      env: {
        'FLUTTER_STORAGE_BASE_URL': Uri.directory(mirror).toString(),
        'GRADLE_USER_HOME': gradle,
      },
    );
    return p.join(
      project,
      'build/app/outputs/flutter-apk/app-${request.flavor == null ? '' : '${request.flavor}-'}release.apk',
    );
  }

  /// Verifies the APK, extracts libapp.so into [dir] and binds it to the request.
  Future<Map<String, dynamic>> verifyApk(
    String apk,
    String dir,
    BuildRequest request,
    String? hostTrust,
  ) async {
    return _bind(
      await verifyBuildApk(
        apk,
        dir,
        aapt,
        commands,
        engine,
        expectedHostTrust: hostTrust,
      ),
      request,
    );
  }

  /// The built package must be exactly what the immutable host policy names.
  Map<String, dynamic> _bind(
    Map<String, dynamic> apkInfo,
    BuildRequest request,
  ) {
    final ios = request.platform == 'ios';
    final code = ios ? 'BUILD_IPA_INVALID' : 'BUILD_APK_INVALID';
    require(
      apkInfo['application_id'] ==
              request.hostPolicy.fields['application_id'] &&
          apkInfo['version_code'] == request.hostPolicy.fields['version_code'],
      code,
      'Actual ${ios ? 'app' : 'APK'} differs from immutable host policy.',
    );
    if (request.versionCode != null) {
      require(
        apkInfo['version_code'] == request.versionCode,
        code,
        'Actual ${ios ? 'CFBundleVersion' : 'versionCode'} differs.',
      );
    }
    return apkInfo;
  }

  Future<void> _writeOutput(
    BuildRequest request,
    String apk,
    Map<String, dynamic> report,
    String name,
  ) async {
    final staging = temporaryName(p.absolute(request.output));
    await Directory(staging).create(recursive: true);
    await File(apk).copy(p.join(staging, name));
    await writeObject(p.join(staging, 'build.json'), report);
    require(
      !await Directory(request.output).exists(),
      'BUILD_CONFIG_INVALID',
      'Output appeared during build.',
    );
    await Directory(staging).renameRetry(p.absolute(request.output));
  }

  Future<void> _recordFailure(String work, String phase, Object error) =>
      writeObject(p.join(work, 'failure.json'), {
        'phase': phase,
        'error': error is Failure ? error.code : error.runtimeType.toString(),
        if (error is Failure) 'message': error.message,
      });
}

typedef StepRunner = Future<String> Function(
  String executable,
  List<String> args, {
  String? cwd,
  Map<String, String>? env,
});
