import 'dart:io';
import '../build/pins.dart';
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
import 'resources.dart';
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
/// The first few rejection reasons of a tools report, one line each.
String checkSummary(Map<String, dynamic> report, {int limit = 3}) {
  final lines = <String>[];
  final checks = report['checks'];
  if (checks is Map) {
    for (final entry in checks.entries) {
      if (entry.value is! List) continue;
      for (final row in entry.value as List) {
        if (row is! Map) continue;
        final message = '${row['message'] ?? row['code']}'.split('\n').first;
        lines.add(
            '${entry.key}: ${message.replaceFirst(RegExp(r'^org-dartlang-root:///'), '')}');
      }
    }
  }
  if (lines.isEmpty) return 'see the report';
  final more = lines.length > limit ? ' (+${lines.length - limit} more)' : '';
  return '${lines.take(limit).join('; ')}$more';
}

void rejectFfi(Map<String, dynamic> report) {
  final sites = (report['checks'] as Map?)?['ffi'];
  if (sites is! List || sites.isEmpty) return;
  final first = sites.first as Map;
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
      trace('baseline');
      final usage = await commands.run(sdk.dart, [tool, '--help']);
      require(usage.contains('compile-patch'), 'TOOLS_VERSION_UNSUPPORTED',
          'Tools with compile-patch support are required; update the tools release');
      phase = 'sources';
      final workspace = BuildWorkspace(work);
      final project =
          await workspace.copyPackage(req.project, application: true);
      trace('copied project');
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
      trace('package inputs');
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
      // Libraries the host never compiled are new only if they changed since
      // the release (older baselines did not record them: all count).
      final released = oldState is Map && oldState[app] is Map
          ? (oldState[app] as Map)['dart_files'] as Map?
          : null;
      for (final name in own) {
        final root = roots[name] as Uri?;
        if (root == null) continue;
        await for (final entity in Directory.fromUri(root)
            .list(recursive: true, followLinks: false)) {
          if (entity is File && entity.path.endsWith('.dart')) {
            final relative = p
                .relative(entity.path, from: root.toFilePath())
                .replaceAll('\\', '/');
            final identity = 'package:$name/$relative';
            if (hashes.containsKey(identity)) continue;
            if (name == app &&
                released != null &&
                released[relative] == await hashFile(entity.path)) {
              continue;
            }
            changed.add(identity);
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
      trace('source changes');
      // The whole tier renames every free package into the module as well.
      // The packages pinned at the host build (native capability and all it
      // reaches) always stay the host's, so changing one needs a release.
      final pinned = (await baselineObject(
          p.join(baseline, 'compile_receipt.json')))['pinned_packages'];
      Set<String>? wholeOwn;
      if (pinned is Map) {
        final changedPackages = {
          for (final c in changed)
            if (c.startsWith('dependency:'))
              c.substring('dependency:'.length)
            else if (c.startsWith('package:'))
              Uri.parse(c).pathSegments.first,
          for (final name in pinned.keys.cast<String>())
            if (!roots.containsKey(name)) name,
        };
        for (final name in changedPackages.toList()..sort()) {
          if (!pinned.containsKey(name)) continue;
          final row = pinned[name] as Map;
          final why = row['reason'] == 'dependency'
              ? 'reached via ${(row['via'] as List).join(' -> ')}'
              : '${row['reason']}';
          final version = oldState is Map && oldState[name] is Map
              ? oldState[name]['version']
              : null;
          throw Failure(
              'PATCH_PINNED_PACKAGE_CHANGED',
              '$name stays in the host ($why), so a patch cannot change it; '
                  'a new host release can. To keep the release\'s copy'
                  '${version == null ? '' : ', add to pubspec.yaml:\n'
                      'dependency_overrides:\n  $name: $version'}');
        }
        final now = await computePackagePins(config, app);
        final added = now.pinned.keys
            .where((n) => !pinned.containsKey(n))
            .toList()
          ..sort();
        require(
            added.isEmpty,
            'PATCH_NATIVE_CHANGE',
            'Packages with native capability, or reached from one, are new '
                'since the release and need a new host release: ${added.join(', ')}');
        wholeOwn = {...own, ...now.free.where((n) => !pinned.containsKey(n))};
      }
      require(
          !dependencyChanged || wholeOwn != null,
          'PATCH_BASELINE_INCOMPATIBLE',
          'This host predates pinned-package records; rebuild it to patch '
              'dependency changes');
      // Both known only once the bundle is built.
      var resources = false;
      var tier = dependencyChanged ? 'whole' : 'lean';
      final modules = <String,
          ({
        Map<String, Object?> remap,
        Map<String, String> names,
        String dir
      })>{};
      Future<
          ({
            Map<String, Object?> remap,
            Map<String, String> names,
            String dir
          })> module(String tier) async {
        if (modules[tier] case final ready?) return ready;
        final dir = p.join(work, tier == 'lean' ? 'module' : 'module-whole');
        final remap = await remapSources(
            config, dir, tier == 'lean' ? own : wholeOwn!, req.seq);
        for (final reserved in ['__patch_entry.dart', '__patch_overlay.dart']) {
          require(!await File(p.join(dir, app, reserved)).exists(),
              'PATCH_SOURCE_INVALID', 'Application uses reserved $reserved');
        }
        return modules[tier] = (
          remap: remap,
          names: Map<String, String>.from(remap['names'] as Map),
          dir: dir
        );
      }

      Future<void> installOverlay(String appDir) async {
        final generated = p.join(appDir, '__patch_overlay.dart');
        if (await File(generated).exists()) return;
        final plugin = roots['flutter_patcher'] as Uri?;
        require(plugin != null, 'PATCH_OVERLAY_UNAVAILABLE',
            'Resource patches require the flutter_patcher dependency');
        final helper =
            File.fromUri(plugin!.resolve('src/bootstrap/overlay.dart'));
        require(await helper.exists(), 'PATCH_OVERLAY_UNAVAILABLE',
            'The flutter_patcher dependency has no resource overlay; use a newer version');
        await helper.copy(generated);
      }

      // Before the bundle build: it shadows hook packages in this config.
      await module(tier);
      Future<Map<String, dynamic>> compile(bool emit) async {
        phase = '$tier-${emit ? 'emit' : 'check'}';
        final m = await module(tier);
        final names = m.names;
        if (resources) await installOverlay(p.join(m.dir, app));
        await File(p.join(m.dir, app, '__patch_entry.dart')).writeAsString(
            patchEntry(names[app]!, req.target.substring(4), req.seq,
                fingerprint, tier,
                resources: resources));
        // As for the baseline kernel: virtual source URIs keep the run's work
        // path (and the developer's directories) out of the shipped module.
        final virtual = usage.contains('filesystem_roots')
            ? await VirtualPackages.write(m.remap['packages'] as String,
                [p.absolute(work), p.absolute(cache)])
            : null;
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
          'packages': virtual?.packagesUri ?? m.remap['packages'],
          if (virtual != null) ...{
            'filesystem_scheme': virtualScheme,
            'filesystem_roots': virtual.roots,
          },
          'baseline': p.join(baseline, 'app.dill'),
          'interface': p.join(baseline, 'dynamic_interface.yaml'),
          'compiler_interface': p.join(baseline, 'compiler_interface.json'),
          'platform':
              p.join(sdk.root, (manifest['platform'] as Map)['path'] as String),
          'allocated': p.join(baseline, 'allocate_finalized.json'),
          'resources': resources,
          if (resources)
            'overlay_library': 'package:${names[app]}/__patch_overlay.dart',
          'own': names.values.toList(),
          'original_own': (tier == 'lean' ? own : wholeOwn!).toList(),
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

      phase = 'resources';
      final bundle = p.join(work, 'flutter_assets');
      // The bundle build compiles the whole app once more just for assets.
      // Meanwhile the module compiles, assuming no asset changed; it is
      // compiled again with the resource overlay if one did. The compile
      // emits right away (the tool emits only when every check passes).
      final bundling = withoutBuildHooks(
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
      Map<String, dynamic>? speculative;
      (Object, StackTrace)? speculativeError;
      final speculation = compile(true).then<void>((r) => speculative = r,
          onError: (Object e, StackTrace s) => speculativeError = (e, s));
      try {
        await bundling;
      } finally {
        await speculation;
        phase = 'resources';
      }
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
      resources = payload.assets.isNotEmpty;
      Map<String, dynamic> outcome;
      if (!resources && speculativeError != null) {
        Error.throwWithStackTrace(speculativeError!.$1, speculativeError!.$2);
      } else if (!resources && speculative != null) {
        outcome = speculative!;
      } else {
        if (speculative != null) reports.remove(speculative);
        outcome = await compile(true);
      }
      // An FFI call in the module is no tier's to fix.
      rejectFfi(outcome);
      final resourceCheck = (outcome['checks'] as Map)['resources'];
      require(
          !resources ||
              resourceCheck is! Map ||
              resourceCheck['verdict'] == 'INJECTABLE',
          'PATCH_RESOURCE_UNSAFE',
          'The changed assets could be read past the patch overlay '
              '(${resourceCheck is Map ? resourceCheck['verdict'] : ''}); '
              'see the resource check in $work. Ship them in a host release.');
      // Lean rejected: the whole tier carries the free packages the module
      // used through the host interface, and may pass.
      if (outcome['status'] != 'compiled' &&
          tier == 'lean' &&
          wholeOwn != null) {
        tier = 'whole';
        outcome = await compile(true);
        rejectFfi(outcome);
      }
      final finalReport = outcome;
      require(
          finalReport['status'] == 'compiled',
          'PATCH_UNSAFE',
          '${tier == 'lean' ? 'Lean' : 'Whole'}-tier checks failed: '
              '${checkSummary(finalReport)}; evidence: $work');
      require(!resources || finalReport['overlay'] is Map, 'PATCH_UNSAFE',
          'Resource transform did not run');
      await payload.collectFonts(finalReport['fonts'] as List? ?? [],
          finalReport['dynamic_fonts'] as List? ?? [],
          hostIcons: finalReport['host_icons'] as List?,
          hostFiles: oldResources['files'] as Map? ?? const {});
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
            'carried_packages': (wholeOwn!.toList()..sort()),
            'message': 'Dependencies other than those pinned to the host run '
                'in the module interpreter.'
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
