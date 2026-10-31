import 'dart:io';
import '../build/runtime_package.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';
import '../core.dart';
import '../baseline/manifest.dart';
import '../baseline/repository.dart';
import '../build/defines.dart';
import '../build/virtual_paths.dart';
import '../build/workspace.dart';
import '../sdk/artifacts.dart';
import '../sdk/package_inputs.dart';
import 'sources.dart';
import 'hooks.dart';
import 'package.dart';
import 'plugins.dart';
import 'resources.dart';
import 'tier_policy.dart';
import 'so_pipeline.dart';

class PatchFailure extends Failure {
  final Map<String, Object?> details;
  PatchFailure(super.code, super.message, this.details);
}

class PatchRequest {
  final String project, privateKey, output, target, flavor;

  /// `android` or `ios`; must match the release's host policy.
  final String platform;
  String get abi => platform == 'ios' ? 'ios-arm64' : 'arm64-v8a';

  /// Optional; when given it must match the resolved release, and it selects
  /// a legacy baseline that has no release binding.
  final String? fingerprint;
  final int seq, minBuild;
  final int? previousSeq;
  final bool offline;
  final List<String> assets;
  PatchRequest(
      {required this.project,
      this.fingerprint,
      this.flavor = 'default',
      required this.privateKey,
      required this.output,
      required this.seq,
      required this.minBuild,
      this.previousSeq,
      this.assets = const [],
      this.target = 'lib/main.dart',
      this.platform = 'android',
      this.offline = false});
  Future<void> validate() async {
    require(
        (fingerprint == null || baselineHash.hasMatch(fingerprint!)) &&
            RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(flavor) &&
            seq > 0 &&
            seq <= 0xffffffff &&
            minBuild > 0 &&
            (previousSeq == null || (previousSeq! >= 0 && seq > previousSeq!)),
        'PATCH_CONFIG_INVALID',
        'Invalid fingerprint, flavor, build number or sequence');
    require(
        target.startsWith('lib/') &&
            !target.split('/').contains('..') &&
            !target.contains('\\') &&
            await File(p.join(project, target)).exists(),
        'PATCH_CONFIG_INVALID',
        'Select an existing lib/ entry');
    await rejectLinks(output);
    require(
        !await FileSystemEntity.isDirectory(output) &&
            !await File(output).exists(),
        'PATCH_CONFIG_INVALID',
        'Use a new output directory');
  }
}

/// Native files that reach each platform's build, besides hook/:
/// - Android: android/ without test sources or Markdown.
/// - iOS: ios/ and darwin/ without tests, Markdown, per-user Xcode state and
///   the files `flutter pub get` regenerates with machine paths.
/// Both sides are filtered at comparison time, so baselines recorded with
/// every native file stay valid.
final _nativeBuildFiles = {
  'android':
      RegExp(r'^(android/(?!(.*/)?src/(test|androidTest)/).*(?<!\.md)$|hook/)'),
  'ios': RegExp(r'^((ios|darwin)/(?!(.*/)?(RunnerTests|xcuserdata)/)'
      r'(?!Flutter/(Generated\.xcconfig|flutter_export_environment\.sh|ephemeral/))'
      r'.*(?<!\.md)(?<!GeneratedPluginRegistrant\.[hm])$|hook/)'),
};

Object? _nativeBuildInputs(Object? entry, String platform) => entry is! Map
    ? entry
    : {
        ...entry,
        'native_files': {
          for (final e in ((entry['native_files'] as Map?) ?? const {}).entries)
            if (_nativeBuildFiles[platform]!.hasMatch(e.key as String))
              e.key: e.value
        }
      };

/// The interpreter cannot make FFI calls in an AOT runtime, so a module that
/// contains one (tools report `checks.ffi`) would abort the app. Older tools
/// do not report the check.
void rejectFfi(Map<String, dynamic> report,
    {Map<String, String> registeredPlugins = const {}}) {
  final sites = (report['checks'] as Map?)?['ffi'];
  if (sites is! List || sites.isEmpty) return;
  final first = sites.first as Map;
  final file = '${first['file']}';
  for (final MapEntry(key: name, value: root) in registeredPlugins.entries) {
    if (file.startsWith('package:$name/') || file.startsWith(root)) {
      throw Failure(
          'PATCH_FFI_UNSUPPORTED',
          'This patch needs the whole tier, which carries its own copy of every '
              'plugin and must register them, but the $name implementation uses '
              'FFI (${first['message']} at $file:${first['line']}), which the '
              'interpreter cannot run. Keep the change within the lean tier (no '
              'dependency changes) or ship a new host release.');
    }
  }
  throw Failure(
      'PATCH_FFI_UNSUPPORTED',
      'Patched code would run FFI in the interpreter (${first['message']} at '
          '${first['file']}:${first['line']}). Keep FFI in unchanged host code, '
          'which a patch may call, or ship a new host release.');
}

/// Rejects native changes against the release's [previous] package inputs and
/// records each changed pure-Dart dependency in [changed]; true if any did.
bool nativeInputChanges(
    Map current, Map previous, String app, List<String> changed,
    {String platform = 'android'}) {
  Map? inputs(Map state, String name) =>
      _nativeBuildInputs(state[name], platform) as Map?;
  require(
      canonical(inputs(current, app)?['native_files']) ==
          canonical(inputs(previous, app)?['native_files']),
      'PATCH_NATIVE_CHANGE',
      'Application native sources changed; rebuild host');
  var any = false;
  for (final name in {
    ...current.keys.cast<String>(),
    ...previous.keys.cast<String>()
  }) {
    if (name == app) continue;
    final now = inputs(current, name), before = inputs(previous, name);
    if (canonical(now) == canonical(before)) continue;
    require(
        now?['native'] != true &&
            before?['native'] != true &&
            (now?['native_files'] as Map? ?? {}).isEmpty &&
            (before?['native_files'] as Map? ?? {}).isEmpty,
        'PATCH_NATIVE_CHANGE',
        'Native plugin/build hook changed: $name');
    any = true;
    changed.add('dependency:$name');
  }
  return any;
}

class PatchPipeline {
  final Commands commands;
  final SdkIdentity sdk;
  final String managed, tool, cache;
  final BaselineRepository baselines;

  /// The engine release record; needed only to rebuild an SO host's APK.
  final Map<String, dynamic>? engine;
  PatchPipeline(this.commands, this.sdk, this.managed, this.tool, this.cache,
      this.baselines,
      {this.engine});
  Future<Map<String, Object?>> patch(PatchRequest req) async {
    await req.validate();
    for (final protected in [sdk.root, managed]) {
      require(
          !p.equals(p.absolute(protected), p.absolute(req.output)) &&
              !p.isWithin(p.absolute(protected), p.absolute(req.output)),
          'PATCH_CONFIG_INVALID',
          'Output cannot be inside a Flutter SDK');
    }
    final work = temporaryName(p.join(cache, 'patches/run'));
    await rejectLinks(work);
    await Directory(work).create(recursive: true);
    var phase = 'baseline';
    final reports = <Map<String, dynamic>>[];
    try {
      final resolved = await baselines.resolve(
          req.flavor, req.minBuild.toString(),
          abi: req.abi,
          expectedFingerprint: req.fingerprint,
          sdkRoot: sdk.root);
      if (resolved.strategy == 'so') {
        phase = 'so';
        return await patchSo(req, resolved, work);
      }
      final fingerprint = resolved.fingerprint;
      // Compile inputs come from the compile object; package names, receipt
      // fields and build_id from the release object.
      final baseline = resolved.compileRoot, release = resolved.releaseRoot;
      final manifest = resolved.compile;
      require(
          manifest['flutter_version'] == sdk.version &&
              manifest['engine_commit'] == sdk.engine,
          'PATCH_BASELINE_INCOMPATIBLE',
          'SDK differs from baseline');
      // Bytecode patches install only on hosts with a host policy.
      require(
          [3, 5].contains(manifest['schema']) &&
              manifest['runtime_bootstrap'] == true &&
              manifest['host_policy_sha256'] is String,
          'BASELINE_NOT_RELEASE',
          'A baseline archived by build ${req.platform} --host-policy is required');
      final receipt = resolved.receipt;
      require(
          req.minBuild.toString() == receipt['version_code'],
          'PATCH_BASELINE_INCOMPATIBLE',
          'Minimum build must match the target release');
      require(receipt['public_key'] is String, 'PATCH_KEY_MISMATCH',
          'Release public key is missing');
      final key = signingKey(req.privateKey,
          expectedPublic: receipt['public_key'] as String);
      final usage = await commands.run(sdk.dart, [tool, '--help']);
      require(usage.contains('compile-patch'), 'TOOLS_VERSION_UNSUPPORTED',
          'Tools with compile-patch support are required; update the tools release');
      phase = 'sources';
      final workspace = BuildWorkspace(work);
      final project =
          await workspace.copyPackage(req.project, application: true);
      await commands.run(
          sdk.host.flutterLauncher(managed),
          [
            '--suppress-analytics',
            'pub',
            'get',
            '--enforce-lockfile',
            if (req.offline) '--offline'
          ],
          cwd: project);
      final config = p.join(project, '.dart_tool/package_config.json');
      final oldRoots =
          await packageRoots(p.join(release, 'package_config.json'));
      final pubspec =
          loadYaml(await File(p.join(project, 'pubspec.yaml')).readAsString())
              as Map;
      final app = pubspec['name'] as String;
      await installRuntimePackage(config, app, req.target.substring(4));
      final roots = await packageRoots(config);
      final packageState = await packageInputs(config, application: app);
      final oldState = receipt['package_inputs'];
      require(oldState is Map, 'PATCH_BASELINE_INCOMPATIBLE',
          'Baseline lacks dependency/native provenance; rebuild host');
      final own = {app, ...roots.keys.where((k) => !oldRoots.containsKey(k))};
      final changed = <String>[];
      var dependencyChanged = false;
      if (oldState is Map) {
        dependencyChanged = nativeInputChanges(
            packageState, oldState, app, changed,
            platform: req.platform);
      }
      final hashes =
          (await readObject(p.join(baseline, 'source_hashes.json')))['files']
              as Map;
      for (final row in hashes.entries) {
        final uri = Uri.parse(row.key as String),
            name = Uri.parse(row.key as String).pathSegments.first;
        final root = roots[name] as Uri?;
        final file = root == null
            ? null
            : File.fromUri(root.resolve(uri.pathSegments.skip(1).join('/')));
        if (file == null ||
            !await file.exists() ||
            await hashFile(file.path) != row.value) {
          changed.add(row.key as String);
          if (name != app) dependencyChanged = true;
        }
      }
      // The generated host.dart imports the host's entry file: a different
      // --target is a mistake, not a dependency change for the whole tier to
      // carry (it would ship the other entry's main).
      require(
          !changed.contains('package:dynamic_modules/host.dart'),
          'PATCH_TARGET_MISMATCH',
          'The host was built from a different entry file than ${req.target}; '
              'patch with the --target the host was built with.');
      for (final name in own) {
        final root = roots[name] as Uri?;
        if (root == null) continue;
        await for (final entity in Directory.fromUri(root)
            .list(recursive: true, followLinks: false)) {
          if (entity is File && entity.path.endsWith('.dart')) {
            final identity =
                'package:$name/${p.relative(entity.path, from: root.toFilePath()).replaceAll('\\', '/')}';
            if (!hashes.containsKey(identity)) changed.add(identity);
          }
        }
      }
      // Native plugin capability cannot be supplied by a Dart module.
      for (final name in roots.keys) {
        if (name == app) continue;
        final spec =
            File.fromUri((roots[name] as Uri).resolve('../pubspec.yaml'));
        if (!await spec.exists()) continue;
        final data = loadYaml(await spec.readAsString());
        final plugin = data is Map &&
            data['flutter'] is Map &&
            (data['flutter'] as Map)['plugin'] != null;
        require(
            !plugin ||
                (oldRoots.containsKey(name) &&
                    !changed.any((c) => c.startsWith('package:$name/'))),
            'PATCH_NATIVE_CHANGE',
            'Native plugin changes require a new host release: $name');
      }
      phase = 'resources';
      final bundle = p.join(work, 'flutter_assets');
      await withoutBuildHooks(
          config,
          p.join(work, 'no-hooks'),
          () => commands.run(
              sdk.host.flutterLauncher(managed),
              [
                '--suppress-analytics',
                'build',
                'bundle',
                '--release',
                '--no-pub',
                '--target-platform',
                req.platform == 'ios' ? 'ios' : 'android-arm64',
                '--target',
                req.target,
                '--asset-dir',
                bundle,
              ],
              cwd: project));
      final payload = PatchResources(bundle, work, commands, managed);
      final oldResources = receipt['resources'];
      require(oldResources is Map, 'PATCH_BASELINE_INCOMPATIBLE',
          'Baseline lacks resource inventory; rebuild host');
      await payload.collect(
          oldResources is Map
              ? Map<String, dynamic>.from(oldResources)
              : {
                  'schema': 1,
                  'files': <String, dynamic>{},
                  'manifest': <String, dynamic>{}
                },
          req.assets);
      if (payload.assets.isNotEmpty) changed.add('resources');
      final resources = payload.assets.isNotEmpty;
      final remap =
          await remapSources(config, p.join(work, 'module'), own, req.seq);
      final names = Map<String, String>.from(remap['names'] as Map);
      if (resources) {
        final plugin = roots['flutter_patcher'] as Uri?;
        require(plugin != null, 'PATCH_OVERLAY_UNAVAILABLE',
            'Resource patches require the flutter_patcher dependency');
        final helper =
            File.fromUri(plugin!.resolve('src/bootstrap/overlay.dart'));
        require(await helper.exists(), 'PATCH_OVERLAY_UNAVAILABLE',
            'The flutter_patcher dependency has no resource overlay; use a newer version');
        final generated = p.join(work, 'module', app, '__patch_overlay.dart');
        require(!await File(generated).exists(), 'PATCH_SOURCE_INVALID',
            'Application uses reserved __patch_overlay.dart');
        await helper.copy(generated);
      }
      final entry = p.join(work, 'module', app, '__patch_entry.dart');
      // Whole-tier modules carry their own plugin copies; the host's Dart
      // plugin registrant only set up the host's.
      final pluginsLibrary =
          p.join(work, 'module', app, '__patch_plugins.dart');
      require(!await File(pluginsLibrary).exists(), 'PATCH_SOURCE_INVALID',
          'Application uses reserved __patch_plugins.dart');
      final registrant = File(p.join(
          project, '.dart_tool/flutter_build/dart_plugin_registrant.dart'));
      final registrations = await registrant.exists()
          ? platformRegistrations(await registrant.readAsString(), req.platform)
          : <PluginRegistration>[];
      final registeredPlugins = {
        for (final r in registrations)
          pluginPackage(r):
              '${roots[pluginPackage(r)] ?? 'package:${pluginPackage(r)}/'}'
      };
      final interfaceYaml = loadYaml(
          await File(p.join(baseline, 'dynamic_interface.yaml'))
              .readAsString()) as Map;
      // Whole keeps only the dart: rows; framework libraries travel in the module.
      final wholeInterface = p.join(work, 'whole-interface.yaml');
      await writeObject(wholeInterface, {
        for (final section in interfaceYaml.keys)
          section as String: [
            for (final row in (interfaceYaml[section] as List? ?? []))
              if ((row['library'] as String).startsWith('dart:')) row
          ]
      });
      // As for the baseline kernel: virtual source URIs keep the run's work
      // path (and the developer's directories) out of the shipped module.
      final virtual = usage.contains('filesystem_roots')
          ? await VirtualPackages.write(remap['packages'] as String,
              [p.absolute(work), p.absolute(cache)])
          : null;
      var tier = 'lean';
      Future<Map<String, dynamic>> compile(bool emit) async {
        phase = '$tier-${emit ? 'emit' : 'check'}';
        final plugins = tier == 'whole' && registrations.isNotEmpty;
        if (plugins) {
          await File(pluginsLibrary).writeAsString(pluginRegistrantSource(
              names[app]!, req.target.substring(4), registrations));
        } else if (await File(pluginsLibrary).exists()) {
          await File(pluginsLibrary).delete();
        }
        await File(entry).writeAsString(patchEntry(
            names[app]!, req.target.substring(4), req.seq, fingerprint, tier,
            resources: resources, plugins: plugins));
        final input = p.join(work, '$phase-request.json'),
            output = p.join(work, '$phase-report.json');
        await writeObject(input, {
          'tier': tier,
          // Lets the whole tier drop Flutter's code for other platforms.
          'target_os': req.platform,
          if (usage.contains('environment_defines'))
            'environment_defines': releaseDefines(req.flavor),
          'emit': emit,
          'seq': req.seq,
          'fingerprint': fingerprint,
          'entry': 'package:${names[app]}/__patch_entry.dart',
          'packages': virtual?.packagesUri ?? remap['packages'],
          if (virtual != null) ...{
            'filesystem_scheme': virtualScheme,
            'filesystem_roots': virtual.roots,
          },
          'baseline': p.join(baseline, 'app.dill'),
          'interface': tier == 'whole'
              ? wholeInterface
              : p.join(baseline, 'dynamic_interface.yaml'),
          'compiler_interface': p.join(baseline, 'compiler_interface.json'),
          'platform':
              p.join(sdk.root, (manifest['platform'] as Map)['path'] as String),
          'allocated': p.join(baseline, 'allocate_finalized.json'),
          'resources': resources,
          if (resources)
            'overlay_library': 'package:${names[app]}/__patch_overlay.dart',
          'own': names.values.toList(),
          'original_own': own.toList(),
          'out': p.join(work, 'module.bc'),
          if (!emit) 'kernel_out': p.join(work, '$tier-analysis.dill'),
        });
        final result = await commands
            .runResult(sdk.dart, [tool, 'compile-patch', '--request', input]);
        await File(p.join(work, '$phase.log'))
            .writeAsString('${result.stdout}\n${result.stderr}');
        require(result.exitCode == 0, 'PATCH_TOOL_FAILED',
            'Compiler/checker failed; evidence: $work');
        // Tools write their report to stdout; CFE incidental diagnostics stay in the log.
        await File(output).writeAsString(result.stdout);
        final report = await readObject(output);
        reports.add(report);
        require(report['status'] != 'compile_failed', 'PATCH_COMPILE_FAILED',
            'Source compilation failed; evidence: $work');
        return report;
      }

      final first = await compile(false);
      // The whole tier cannot remove an FFI call; it only carries more code.
      rejectFfi(first);
      final resourceCheck = (first['checks'] as Map)['resources'];
      final resourceUpgrade = resources &&
          resourceCheck is Map &&
          resourceCheck['verdict'] != 'INJECTABLE';
      tier = selectPatchTier(
          leanChecked: first['status'] == 'checked',
          dependencyChanged: dependencyChanged,
          resourceUpgrade: resourceUpgrade);
      if (tier == 'whole') {
        final whole = await compile(false);
        rejectFfi(whole, registeredPlugins: registeredPlugins);
        require(whole['status'] == 'checked', 'PATCH_UNSAFE',
            'Whole-tier checks failed; evidence: $work');
      }
      final finalReport = await compile(true);
      require(finalReport['status'] == 'compiled', 'PATCH_UNSAFE',
          'Final compiler checks failed; evidence: $work');
      require(!resources || finalReport['overlay'] is Map, 'PATCH_UNSAFE',
          'Resource transform did not run');
      await payload.collectFonts(finalReport['fonts'] as List? ?? [],
          finalReport['dynamic_fonts'] as List? ?? []);
      // Font-only changes are meaningful even when all Dart hashes match.
      if (payload.fonts.isNotEmpty) {
        final current = File(p.join(bundle, 'FontManifest.json'));
        final oldFiles =
            oldResources is Map ? oldResources['files'] as Map : const {};
        if (await current.exists() &&
            await hashFile(current.path) !=
                oldFiles['FontManifest.json']?['sha256']) {
          changed.add('fonts');
        }
        final definitions = await readObjectFontSources(bundle);
        for (final key in definitions) {
          if (await hashFile(p.join(bundle, key)) != oldFiles[key]?['sha256']) {
            changed.add('font:$key');
          }
        }
      }
      require(changed.isNotEmpty, 'PATCH_NO_CHANGES',
          'No Dart, dependency or resource changes detected');
      phase = 'package';
      final artifact = await packPatch(
          module: p.join(work, 'module.bc'),
          work: work,
          key: key,
          commands: commands,
          extraEntries: payload.entries,
          fonts: payload.fonts,
          assets: payload.assets,
          metadata: {
            'format_version': 1,
            'patch_seq': req.seq,
            'fingerprint': fingerprint,
            'tier': tier,
            'flutter_version': sdk.version,
            'engine_commit': sdk.engine,
            'build_id': resolved.buildId,
            // Signed: publication accepts the patch for this release only.
            if (resolved.target != null) 'target': resolved.target,
          });
      await workspace.verifyOriginals();
      await baselines.recheck(resolved, sdkRoot: sdk.root);
      final report = <String, Object?>{
        'status': 'patch_created',
        'platform': req.platform,
        'abi': req.abi,
        'strategy': 'bytecode',
        'fingerprint': fingerprint,
        'patch_seq': req.seq,
        'min_build': req.minBuild,
        'tier': tier,
        if (tier == 'whole')
          'upgrade': {
            'dependency_changed': dependencyChanged,
            'message':
                'Framework code runs in the module interpreter; startup, scrolling and memory may regress.'
          },
        'changed': changed,
        'sha256': artifact['sha256'],
        'bytes': artifact['bytes'],
        'checks': reports,
        'device_verified': false,
        'release_baseline_verified': true,
        'release': resolved.report,
        'baseline_cache': {
          'compile': resolved.compileRoot,
          'release': resolved.releaseRoot
        },
        'work': work
      };
      return await writeOutput(req, artifact['file'] as String, report);
    } catch (error) {
      await writeObject(p.join(work, 'failure.json'), {
        'phase': phase,
        'code': error is Failure ? error.code : error.runtimeType.toString()
      });
      if (error is Failure) {
        throw PatchFailure(error.code, error.message,
            {'phase': phase, 'work': work, 'checks': reports});
      }
      rethrow;
    }
  }

  /// Moves the envelope and report into the request's new output directory.
  Future<Map<String, Object?>> writeOutput(
      PatchRequest req, String artifact, Map<String, Object?> report) async {
    final pending = temporaryName(p.absolute(req.output));
    await Directory(pending).create(recursive: true);
    await File(artifact).copy(p.join(pending, 'patch.fptc'));
    await writeObject(p.join(pending, 'patch.json'), report);
    await rejectLinks(req.output);
    require(
        await FileSystemEntity.type(req.output, followLinks: false) ==
            FileSystemEntityType.notFound,
        'PATCH_CONFIG_INVALID',
        'Output appeared during compilation');
    await Directory(pending).renameRetry(p.absolute(req.output));
    return {...report, 'output': p.absolute(req.output)};
  }
}
