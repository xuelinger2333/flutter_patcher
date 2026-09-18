import 'dart:io';
import '../build/runtime_package.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';
import '../core.dart';
import '../baseline/manifest.dart';
import '../baseline/repository.dart';
import '../build/workspace.dart';
import '../sdk/artifacts.dart';
import '../sdk/package_inputs.dart';
import 'sources.dart';
import 'package.dart';
import 'resources.dart';
import 'tier_policy.dart';
import 'framework_carry.dart';

class PatchFailure extends Failure {
  final Map<String, Object?> details;
  PatchFailure(super.code, super.message, this.details);
}

class PatchRequest {
  final String project, fingerprint, privateKey, output, target;
  final int seq, minBuild;
  final int? previousSeq;
  final bool validationOnly, offline, frameworkReuse;
  final List<String> assets;
  PatchRequest(
      {required this.project,
      required this.fingerprint,
      required this.privateKey,
      required this.output,
      required this.seq,
      required this.minBuild,
      this.previousSeq,
      this.assets = const [],
      this.target = 'lib/main.dart',
      this.validationOnly = false,
      this.offline = false,
      this.frameworkReuse = false});
  Future<void> validate() async {
    require(
        baselineHash.hasMatch(fingerprint) &&
            seq > 0 &&
            seq <= 0xffffffff &&
            minBuild > 0 &&
            (previousSeq == null || (previousSeq! >= 0 && seq > previousSeq!)),
        'PATCH_CONFIG_INVALID',
        'Invalid fingerprint, build number or sequence');
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

class PatchPipeline {
  final Commands commands;
  final SdkIdentity sdk;
  final String managed, tool, cache;
  final BaselineRepository baselines;
  PatchPipeline(this.commands, this.sdk, this.managed, this.tool, this.cache,
      this.baselines);
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
      final baseline =
          await baselines.fetch(req.fingerprint, sdkRoot: sdk.root);
      final manifest = await verifyBaseline(baseline,
          expected: req.fingerprint, sdkRoot: sdk.root);
      require(
          manifest['flutter_version'] == sdk.version &&
              manifest['engine_commit'] == sdk.engine,
          'PATCH_BASELINE_INCOMPATIBLE',
          'SDK differs from baseline');
      require(
          req.validationOnly ||
              ([2, 3, 4].contains(manifest['schema']) &&
                  manifest['runtime_bootstrap'] == true),
          'BASELINE_NOT_RELEASE',
          'A formal WP-5 release baseline is required');
      final receipt = await readObject(p.join(baseline, 'build_receipt.json'));
      require(
          req.minBuild.toString() == receipt['version_code'],
          'PATCH_BASELINE_INCOMPATIBLE',
          'Minimum build must match the target release');
      require(req.validationOnly || receipt['public_key'] is String,
          'PATCH_KEY_MISMATCH', 'Release public key is missing');
      final key = await signingKey(req.privateKey, work, commands,
          expectedPublic:
              req.validationOnly ? null : receipt['public_key'] as String);
      final usage = await commands.run(sdk.dart, [tool, '--help']);
      require(usage.contains('compile-patch'), 'TOOLS_VERSION_UNSUPPORTED',
          'CI tools with WP-6 support are required');
      final partitionPath = p.join(baseline, 'framework_partition.json');
      final partition =
          manifest['schema'] == 4 ? await baselineObject(partitionPath) : null;
      phase = 'sources';
      final workspace = BuildWorkspace(work);
      final project =
          await workspace.copyPackage(req.project, application: true);
      await commands.run(
          p.join(managed, 'bin/flutter'),
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
          await packageRoots(p.join(baseline, 'package_config.json'));
      final pubspec =
          loadYaml(await File(p.join(project, 'pubspec.yaml')).readAsString())
              as Map;
      final app = pubspec['name'] as String;
      if (!req.validationOnly) {
        await installRuntimePackage(config, app, req.target.substring(4));
      }
      final roots = await packageRoots(config);
      final packageState = await packageInputs(config, application: app);
      final oldState = receipt['package_inputs'];
      require(
          req.validationOnly || oldState is Map,
          'PATCH_BASELINE_INCOMPATIBLE',
          'Baseline lacks dependency/native provenance; rebuild host');
      final own = {app, ...roots.keys.where((k) => !oldRoots.containsKey(k))};
      final changed = <String>[];
      var dependencyChanged = false;
      if (oldState is Map) {
        require(
            canonical(packageState[app]?['native_files']) ==
                canonical(oldState[app]?['native_files']),
            'PATCH_NATIVE_CHANGE',
            'Application native sources changed; rebuild host');
        for (final name in {
          ...packageState.keys,
          ...oldState.keys.cast<String>()
        }) {
          if (name == app) continue;
          final current = packageState[name], previous = oldState[name];
          if (canonical(current) != canonical(previous)) {
            require(
                current?['native'] != true &&
                    previous?['native'] != true &&
                    (current?['native_files'] as Map? ?? {}).isEmpty &&
                    (previous?['native_files'] as Map? ?? {}).isEmpty,
                'PATCH_NATIVE_CHANGE',
                'Native plugin/build hook changed: $name');
            dependencyChanged = true;
            changed.add('dependency:$name');
          }
        }
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
      await commands.run(
          p.join(managed, 'bin/flutter'),
          [
            '--suppress-analytics',
            'build',
            'bundle',
            '--release',
            '--no-pub',
            '--target-platform',
            'android-arm64',
            '--target',
            req.target,
            '--asset-dir',
            bundle,
          ],
          cwd: project);
      final payload = PatchResources(bundle, work, commands, managed);
      final oldResources = receipt['resources'];
      require(
          oldResources is Map || req.validationOnly,
          'PATCH_BASELINE_INCOMPATIBLE',
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
            'WP-7 flutter_patcher dependency is required');
        final helper =
            File.fromUri(plugin!.resolve('src/bootstrap/overlay.dart'));
        require(await helper.exists(), 'PATCH_OVERLAY_UNAVAILABLE',
            'WP-7 overlay source is missing');
        final generated = p.join(work, 'module', app, '__patch_overlay.dart');
        require(!await File(generated).exists(), 'PATCH_SOURCE_INVALID',
            'Application uses reserved __patch_overlay.dart');
        await helper.copy(generated);
      }
      final entry = p.join(work, 'module', app, '__patch_entry.dart');
      final interfaceYaml = loadYaml(
          await File(p.join(baseline, 'dynamic_interface.yaml'))
              .readAsString()) as Map;
      final wholeInterface = p.join(work, 'whole-interface.yaml');
      final fullWholeInterface = p.join(work, 'whole-full-interface.yaml');
      final reuseRequested = req.frameworkReuse &&
          partition != null &&
          usage.contains('framework-reuse');
      await writeObject(wholeInterface, {
        for (final section in interfaceYaml.keys)
          section as String: [
            for (final row in (interfaceYaml[section] as List? ?? []))
              if ((row['library'] as String).startsWith('dart:') ||
                  (reuseRequested &&
                      (row['library'] as String)
                          .startsWith('package:flutter/')))
                row
          ]
      });
      await writeObject(fullWholeInterface, {
        for (final section in interfaceYaml.keys)
          section as String: [
            for (final row in (interfaceYaml[section] as List? ?? []))
              if ((row['library'] as String).startsWith('dart:')) row
          ]
      });
      var tier = 'lean';
      var reuseEnabled = false;
      String? carryPackages;
      final carryOwn = <String>{};
      // The partition is a superset computed for the Flutter release.  A
      // patch only materialises the framework libraries that this particular
      // module needs; passing the complete partition here would make the
      // compiler expect sources that were deliberately not copied.
      Set<String> selectedCarry = <String>{};
      Future<Map<String, dynamic>> compile(bool emit,
          {bool reuse = false}) async {
        phase = '$tier-${emit ? 'emit' : 'check'}';
        await File(entry).writeAsString(patchEntry(names[app]!,
            req.target.substring(4), req.seq, req.fingerprint, tier,
            resources: resources));
        final input = p.join(work, '$phase-request.json'),
            output = p.join(work, '$phase-report.json');
        await writeObject(input, {
          'tier': tier,
          'emit': emit,
          'seq': req.seq,
          'fingerprint': req.fingerprint,
          'entry': 'package:${names[app]}/__patch_entry.dart',
          'packages': carryPackages ?? remap['packages'],
          'baseline': p.join(baseline, 'app.dill'),
          'interface': tier == 'whole'
              ? (reuse ? wholeInterface : fullWholeInterface)
              : p.join(baseline, 'dynamic_interface.yaml'),
          'compiler_interface': p.join(baseline, 'compiler_interface.json'),
          'platform':
              p.join(sdk.root, (manifest['platform'] as Map)['path'] as String),
          'allocated': p.join(baseline, 'allocate_finalized.json'),
          'resources': resources,
          if (resources)
            'overlay_library': 'package:${names[app]}/__patch_overlay.dart',
          'own': [...names.values, ...carryOwn],
          'original_own': own.toList(),
          'out': p.join(work, 'module.bc'),
          if (!emit) 'kernel_out': p.join(work, '$tier-analysis.dill'),
          if (reuse)
            'framework_reuse': {
              'enabled': true,
              'partition': partitionPath,
              'carried': selectedCarry.toList()..sort(),
              'carry_package': carryOwn.single,
            },
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
      final resourceCheck = (first['checks'] as Map)['resources'];
      final resourceUpgrade = resources &&
          resourceCheck is Map &&
          resourceCheck['verdict'] != 'INJECTABLE';
      tier = selectPatchTier(
          leanChecked: first['status'] == 'checked',
          dependencyChanged: dependencyChanged,
          resourceUpgrade: resourceUpgrade);
      Map<String, Object?>? frameworkReuseInfo;
      final frameworkReuseReasons = <Map<String, Object?>>[];
      if (tier == 'whole') {
        final whole = await compile(false);
        require(whole['status'] == 'checked', 'PATCH_UNSAFE',
            'Whole-tier checks failed; evidence: $work');
        // A lean rejection can happen before the framework libraries are
        // emitted, so `module_libraries` alone is not a complete description
        // of M0.  Allocation and interface diagnostics carry the authoritative
        // library URI for each cross-boundary framework use; collect those
        // together with any libraries the compiler did report explicitly.
        final candidate = <String>{
          for (final uri in ((first['module_libraries'] as List?) ?? const []))
            if (uri is String && uri.startsWith('package:flutter/')) uri
        };
        void collectFrameworkLibraries(Object? value) {
          if (value is Map) {
            final uri = value['library'];
            if (uri is String && uri.startsWith('package:flutter/')) {
              candidate.add(uri);
            }
            for (final child in value.values) {
              collectFrameworkLibraries(child);
            }
          } else if (value is List) {
            for (final child in value) {
              collectFrameworkLibraries(child);
            }
          }
        }

        collectFrameworkLibraries(first['checks']);
        final available = partition == null
            ? <String>{}
            : (partition['carry'] as List).cast<String>().toSet();
        final hostBarrels = partition == null
            ? <String>{}
            : {
                for (final row in (partition['libraries'] as List? ?? const []))
                  if (row is Map &&
                      row['role'] == 'host' &&
                      (row['declarations'] as List? ?? const []).isEmpty)
                    row['uri'] as String
              };
        final missing = candidate
            .where(
                (uri) => !available.contains(uri) && !hostBarrels.contains(uri))
            .toSet();
        final effectiveCandidate =
            candidate.where((uri) => !hostBarrels.contains(uri)).toSet();
        if (reuseRequested &&
            effectiveCandidate.isNotEmpty &&
            missing.isEmpty &&
            available.containsAll(effectiveCandidate)) {
          final selected = effectiveCandidate.where(available.contains).toSet();
          selectedCarry = selected;
          final carry = await prepareFrameworkCarry(
              partition: partitionPath,
              sdkRoot: sdk.root,
              destination: p.join(work, 'module'),
              packagesConfig: remap['packages'] as String,
              seq: req.seq,
              selected: selected);
          carryPackages = carry['packages'] as String;
          carryOwn.add(carry['package'] as String);
          final rewrites =
              (carry['uri_rewrites'] as Map).cast<String, String>();
          for (final package in own) {
            final directory = Directory(p.join(work, 'module', package));
            if (!await directory.exists()) continue;
            await for (final entity
                in directory.list(recursive: true, followLinks: false)) {
              if (entity is! File || !entity.path.endsWith('.dart')) continue;
              await entity.writeAsString(rewriteImports(
                  await entity.readAsString(), names,
                  uriRewrites: rewrites));
            }
          }
          reuseEnabled = true;
          frameworkReuseInfo = {
            'enabled': true,
            'partition_sha256': await hashFile(partitionPath),
            'carried': (carry['carried'] as List).cast<String>(),
            'host_bound_count': available.length - selected.length,
          };
          final reuseCheck = await compile(false, reuse: true);
          require(reuseCheck['status'] == 'checked', 'PATCH_UNSAFE',
              'Framework reuse checks failed; evidence: $work');
        } else if (reuseRequested && effectiveCandidate.isNotEmpty) {
          final reason = missing.isEmpty
              ? effectiveCandidate.join(', ')
              : missing.join(', ');
          frameworkReuseReasons.add({
            'code': 'FRAMEWORK_NOT_CARRIABLE',
            'message':
                'Framework library set requires host declarations: $reason',
            'libraries':
                (missing.isEmpty ? effectiveCandidate : missing).toList()
          });
        }
      }
      final finalReport = await compile(true, reuse: reuseEnabled);
      require(finalReport['status'] == 'compiled', 'PATCH_UNSAFE',
          'Final compiler checks failed; evidence: $work');
      if (reuseEnabled) {
        // Prove on the artifact that only the planned framework copies are in
        // the module and no original package:flutter library leaked in.
        phase = 'structure';
        final structure = await commands.runResult(sdk.dart, [
          tool,
          'verify-structure',
          '--bytecode',
          p.join(work, 'module.bc'),
          '--expect-prefix',
          'package:patch.${req.seq}.',
          '--forbid-prefix',
          'package:$app/',
          '--framework-reuse',
          partitionPath,
          '--carry-package',
          'package:${carryOwn.single}',
          '--expected-carried',
          selectedCarry.join(','),
        ]);
        await File(p.join(work, 'structure.log'))
            .writeAsString('${structure.stdout}\n${structure.stderr}');
        require(structure.exitCode == 0, 'PATCH_TOOL_FAILED',
            'Structure check failed to run; evidence: $work');
        await File(p.join(work, 'structure.json'))
            .writeAsString(structure.stdout);
        final verdict = await readObject(p.join(work, 'structure.json'));
        require(verdict['ok'] == true, 'PATCH_UNSAFE',
            'Framework reuse structure check failed; evidence: $work');
      }
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
            'fingerprint': req.fingerprint,
            'tier': tier,
            'flutter_version': sdk.version,
            'engine_commit': sdk.engine,
            'build_id': manifest['build_id'],
            if (frameworkReuseInfo != null)
              'framework_reuse': frameworkReuseInfo
          });
      await workspace.verifyOriginals();
      await verifyBaseline(baseline,
          expected: req.fingerprint, sdkRoot: sdk.root);
      final report = <String, Object?>{
        'status':
            req.validationOnly ? 'patch_pipeline_validated' : 'patch_created',
        'platform': 'android',
        'abi': 'arm64-v8a',
        'strategy': 'bytecode',
        'fingerprint': req.fingerprint,
        'patch_seq': req.seq,
        'min_build': req.minBuild,
        'tier': tier,
        if (frameworkReuseInfo != null) 'framework_reuse': frameworkReuseInfo,
        if (tier == 'whole')
          'upgrade': {
            'dependency_changed': dependencyChanged,
            'framework_reuse': frameworkReuseInfo ??
                {'enabled': false, 'reasons': frameworkReuseReasons},
            'message':
                'Framework code runs in the module interpreter; startup, scrolling and memory may regress.'
          },
        'changed': changed,
        'sha256': artifact['sha256'],
        'bytes': artifact['bytes'],
        'checks': reports,
        'device_verified': false,
        'release_baseline_verified': !req.validationOnly,
        'work': work
      };
      final pending = temporaryName(p.absolute(req.output));
      await Directory(pending).create(recursive: true);
      await File(artifact['file'] as String).copy(p.join(
          pending, req.validationOnly ? 'validation.fptc' : 'patch.fptc'));
      await writeObject(p.join(pending, 'patch.json'), report);
      await rejectLinks(req.output);
      require(
          await FileSystemEntity.type(req.output, followLinks: false) ==
              FileSystemEntityType.notFound,
          'PATCH_CONFIG_INVALID',
          'Output appeared during compilation');
      await Directory(pending).rename(p.absolute(req.output));
      return {...report, 'output': p.absolute(req.output)};
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
}
