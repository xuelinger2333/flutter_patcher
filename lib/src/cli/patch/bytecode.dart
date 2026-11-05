import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import '../core.dart';
import '../baseline/manifest.dart';
import '../build/defines.dart';
import '../build/pins.dart';
import '../build/virtual_paths.dart';
import 'hooks.dart';
import 'pipeline.dart';
import 'rules.dart';
import 'sources.dart';

typedef _Module = ({
  Map<String, Object?> remap,
  Map<String, String> names,
  String dir,
});

/// A bytecode host's patch: a dynamic module of the changed code, linked
/// against the host. The lean tier carries the application's own packages;
/// the whole tier also every free dependency.
class BytecodeProducer implements CodeProducer {
  BytecodeProducer(this.run);
  final PatchRun run;
  late final String usage;
  late final Map<String, dynamic> compileReceipt;
  late Set<String> own;
  Set<String>? wholeOwn;
  late String tier;
  bool dependencyChanged = false;

  PatchPipeline get _p => run.pipeline;
  String get _baseline => run.resolved.compileRoot;

  @override
  Future<void> prepare() async {
    final manifest = run.resolved.compile;
    require(
      run.resolved.receipt['module_identity'] == 1,
      'PATCH_BASELINE_INCOMPATIBLE',
      'Rebuild this bytecode host to support publication-time sequences.',
    );
    require(
      manifest['flutter_version'] == _p.sdk.version &&
          manifest['engine_commit'] == _p.sdk.engine,
      'PATCH_BASELINE_INCOMPATIBLE',
      'SDK differs from baseline',
    );
    // Bytecode patches install only on hosts with a host policy.
    require(
      [3, 5].contains(manifest['schema']) &&
          manifest['runtime_bootstrap'] == true &&
          manifest['host_policy_sha256'] is String,
      'BASELINE_NOT_RELEASE',
      'A baseline archived by build ${run.req.platform} is required',
    );
    usage = await _p.commands.run(_p.sdk.dart, [_p.tool, '--help']);
    require(
      usage.contains('compile-patch'),
      'TOOLS_VERSION_UNSUPPORTED',
      'Tools with compile-patch support are required; update the tools release',
    );
    compileReceipt = await baselineObject(
      p.join(_baseline, 'compile_receipt.json'),
    );
  }

  @override
  Future<void> inputs(bool dependencyChanged) async {
    final facts = run.facts, changed = facts.changed, app = run.app;
    final oldState = run.receipt['package_inputs'] as Map;
    final oldRoots = await packageRoots(
      p.join(run.resolved.releaseRoot, 'package_config.json'),
    );
    final roots = await packageRoots(run.config);
    own = {app, ...roots.keys.where((k) => !oldRoots.containsKey(k))};
    final hashes =
        (await readObject(p.join(_baseline, 'source_hashes.json')))['files']
            as Map;
    for (final row in hashes.entries) {
      final uri = Uri.parse(row.key as String), name = uri.pathSegments.first;
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
      'The host was built from a different entry file than ${run.req.target}; '
          'patch with the --target the host was built with.',
    );
    // Libraries the host never compiled are new only if they changed since
    // the release (older baselines did not record them: all count).
    final released = oldState[app] is Map
        ? (oldState[app] as Map)['dart_files'] as Map?
        : null;
    for (final name in own) {
      final root = roots[name] as Uri?;
      if (root == null) continue;
      await for (final entity in Directory.fromUri(
        root,
      ).list(recursive: true, followLinks: false)) {
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
      final spec = File.fromUri(
        (roots[name] as Uri).resolve('../pubspec.yaml'),
      );
      if (!await spec.exists()) continue;
      final data = loadYaml(await spec.readAsString());
      final plugin =
          data is Map &&
          data['flutter'] is Map &&
          (data['flutter'] as Map)['plugin'] != null;
      if (plugin &&
          (!oldRoots.containsKey(name) ||
              changed.any((c) => c.startsWith('package:$name/')))) {
        facts.changedPlugins.add(name);
      }
    }
    trace('source changes');
    // The whole tier renames every free package into the module as well.
    // The packages pinned at the host build (native capability and all it
    // reaches) always stay the host's, so changing one needs a release.
    final pinned = compileReceipt['pinned_packages'];
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
        facts.changedPinned[name] = (
          why: row['reason'] == 'dependency'
              ? 'reached via ${(row['via'] as List).join(' -> ')}'
              : '${row['reason']}',
          version: oldState[name] is Map ? oldState[name]['version'] : null,
        );
      }
      final now = await computePackagePins(run.config, app);
      facts.newlyPinned.addAll(
        now.pinned.keys.where((n) => !pinned.containsKey(n)).toList()..sort(),
      );
      wholeOwn = {...own, ...now.free.where((n) => !pinned.containsKey(n))};
    }
    require(
      !dependencyChanged || wholeOwn != null,
      'PATCH_BASELINE_INCOMPATIBLE',
      'This host predates pinned-package records; rebuild it to patch '
          'dependency changes',
    );
    this.dependencyChanged = dependencyChanged;
    tier = dependencyChanged ? 'whole' : 'lean';
  }

  final Map<String, _Module> _modules = {};
  Future<_Module> _module(String tier) async {
    if (_modules[tier] case final ready?) return ready;
    final dir = p.join(run.work, tier == 'lean' ? 'module' : 'module-whole');
    final remap = await remapSources(
      run.config,
      dir,
      tier == 'lean' ? own : wholeOwn!,
      run.req.moduleId,
    );
    require(
      !await File(p.join(dir, run.app, '__patch_entry.dart')).exists(),
      'PATCH_SOURCE_INVALID',
      'Application uses reserved __patch_entry.dart',
    );
    return _modules[tier] = (
      remap: remap,
      names: Map<String, String>.from(remap['names'] as Map),
      dir: dir,
    );
  }

  Future<Map<String, dynamic>> _compile(bool emit) async {
    final req = run.req, work = run.work;
    run.phase = '$tier-${emit ? 'emit' : 'check'}';
    final m = await _module(tier);
    final names = m.names;
    await File(p.join(m.dir, run.app, '__patch_entry.dart')).writeAsString(
      patchEntry(
        names[run.app]!,
        req.target.substring(4),
        req.moduleId,
        run.resolved.fingerprint,
        tier,
      ),
    );
    // As for the baseline kernel: virtual source URIs keep the run's work
    // path (and the developer's directories) out of the shipped module.
    final virtual = usage.contains('filesystem_roots')
        ? await VirtualPackages.write(m.remap['packages'] as String, [
            p.absolute(work),
            p.absolute(_p.cache),
          ])
        : null;
    final input = p.join(work, '${run.phase}-request.json'),
        output = p.join(work, '${run.phase}-report.json');
    await writeObject(input, {
      'tier': tier,
      // Lets the whole tier drop Flutter's code for other platforms.
      'target_os': req.platform,
      if (usage.contains('environment_defines'))
        'environment_defines': releaseDefines(req.flavor),
      'emit': emit,
      // Tools call this module identity 'seq'; it is not patch_seq.
      'seq': req.moduleId,
      'fingerprint': run.resolved.fingerprint,
      'entry': 'package:${names[run.app]}/__patch_entry.dart',
      'packages': virtual?.packagesUri ?? m.remap['packages'],
      if (virtual != null) ...{
        'filesystem_scheme': virtualScheme,
        'filesystem_roots': virtual.roots,
      },
      'baseline': p.join(_baseline, 'app.dill'),
      'interface': p.join(_baseline, 'dynamic_interface.yaml'),
      'compiler_interface': p.join(_baseline, 'compiler_interface.json'),
      'platform': p.join(
        _p.sdk.root,
        (run.resolved.compile['platform'] as Map)['path'] as String,
      ),
      'allocated': p.join(_baseline, 'allocate_finalized.json'),
      'own': names.values.toList(),
      'original_own': (tier == 'lean' ? own : wholeOwn!).toList(),
      'out': p.join(work, 'module.bc'),
      if (!emit) 'kernel_out': p.join(work, '$tier-analysis.dill'),
    });
    final result = await _p.commands.runResult(_p.sdk.dart, [
      _p.tool,
      'compile-patch',
      '--request',
      input,
    ]);
    await File(p.join(work, '${run.phase}.log'))
        .writeAsString('${result.stdout}\n${result.stderr}');
    if (result.exitCode != 0) {
      throw stepFailure('PATCH_TOOL_FAILED', 'Compiler/checker', result, work);
    }
    // Tools write their report to stdout; CFE incidental diagnostics stay in the log.
    await File(output).writeAsString(result.stdout);
    final report = await readObject(output);
    // The host's icon list only feeds font subsetting; reports keep its size.
    run.reports.add({
      for (final entry in report.entries)
        if (entry.key != 'host_icons') entry.key: entry.value,
      if (report['host_icons'] case final List icons)
        'host_icon_count': icons.length,
    });
    require(
      report['status'] != 'compile_failed',
      'PATCH_COMPILE_FAILED',
      'Source compilation failed; evidence: $work',
    );
    run.facts.report = report;
    run.rules.check(PatchStage.compile, run.facts);
    return report;
  }

  @override
  Future<PatchCode> produce() async {
    final req = run.req, work = run.work, sdk = _p.sdk;
    // Before the bundle build: it shadows hook packages in this config.
    await _module(tier);
    run.phase = 'resources';
    final bundle = p.join(work, 'flutter_assets');
    // The bundle build compiles the whole app once more just for assets.
    // Meanwhile the module compiles: assets never change it. The compile
    // emits right away (the tool emits only when every check passes).
    final bundling = withoutBuildHooks(
      run.config,
      p.join(work, 'no-hooks'),
      () => _p.commands.run(sdk.host.flutterLauncher(_p.managed), [
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
      ], cwd: run.project),
    );
    final compiling = _compile(true);
    try {
      await bundling;
    } catch (_) {
      await compiling.then<void>((_) {}, onError: (_) {});
      rethrow;
    }
    var outcome = await compiling;
    // Lean rejected: the whole tier carries the free packages the module
    // used through the host interface, and may pass.
    if (outcome['status'] != 'compiled' && tier == 'lean' && wholeOwn != null) {
      tier = 'whole';
      outcome = await _compile(true);
    }
    run.facts
      ..tier = tier
      ..report = outcome;
    final hostFiles = (run.receipt['resources'] as Map?)?['files'] as Map?;
    return PatchCode(
      kind: 'bytecode',
      file: p.join(work, 'module.bc'),
      bundle: bundle,

      fonts: (payload) => payload.collectFonts(
        outcome['fonts'] as List? ?? [],
        hostIcons: outcome['host_icons'] as List?,
        hostFiles: hostFiles ?? const {},
      ),
      metadata: {'tier': tier},
      report: {
        'tier': tier,
        if (tier == 'whole')
          'upgrade': {
            'dependency_changed': dependencyChanged,
            'carried_packages': (wholeOwn!.toList()..sort()),
            'message':
                'Dependencies other than those pinned to the host run '
                'in the module interpreter.',
          },
      },
    );
  }
}
