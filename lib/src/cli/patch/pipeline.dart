import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import '../core.dart';
import '../run_work.dart';
import '../baseline/manifest.dart';
import '../baseline/repository.dart';
import '../build/host_policy.dart';
import '../build/runtime_package.dart';
import '../publish/trust.dart';
import '../build/workspace.dart';
import '../sdk/artifacts.dart';
import '../sdk/package_inputs.dart';
import 'bytecode.dart';
import 'libapp.dart';
import 'package.dart';
import 'resources.dart';
import 'rules.dart';
import 'scan.dart';
import 'sources.dart';

class PatchFailure extends Failure {
  final Map<String, Object?> details;
  PatchFailure(super.code, super.message, this.details);
}

class PatchRequest {
  final String project, output, target, flavor;

  /// `android` or `ios`; must match the release's host policy.
  final String platform;
  String get abi => platform == 'ios' ? 'ios-arm64' : 'arm64-v8a';

  /// Optional; when given it must match the resolved release, and it selects
  /// a legacy baseline that has no release binding.
  final String? fingerprint;
  final int seq, minBuild;

  final bool offline;
  final List<String> assets;
  PatchRequest({
    required this.project,
    this.fingerprint,
    this.flavor = 'default',
    required this.output,
    required this.seq,
    required this.minBuild,
    this.assets = const [],
    this.target = 'lib/main.dart',
    this.platform = 'android',
    this.offline = false,
  });
  Future<void> validate() async {
    require(
      (fingerprint == null || baselineHash.hasMatch(fingerprint!)) &&
          RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(flavor) &&
          seq > 0 &&
          seq <= 0xffffffff &&
          minBuild > 0,
      'PATCH_CONFIG_INVALID',
      'Invalid fingerprint, flavor, build number or sequence',
    );
    require(
      target.startsWith('lib/') &&
          !target.split('/').contains('..') &&
          !target.contains('\\') &&
          await File(p.join(project, target)).exists(),
      'PATCH_CONFIG_INVALID',
      'Select an existing lib/ entry',
    );
    await rejectLinks(output);
    require(
      !await FileSystemEntity.isDirectory(output) &&
          !await File(output).exists(),
      'PATCH_CONFIG_INVALID',
      'Use a new output directory',
    );
  }
}

/// Native files that reach each platform's build, besides hook/:
/// - Android: android/ without test sources or Markdown.
/// - iOS: ios/ and darwin/ without tests, Markdown, per-user Xcode state and
///   the files `flutter pub get` regenerates with machine paths.
/// Both sides are filtered at comparison time, so baselines recorded with
/// every native file stay valid.
final _nativeBuildFiles = {
  'android': RegExp(
    r'^(android/(?!(.*/)?src/(test|androidTest)/).*(?<!\.md)$|hook/)',
  ),
  'ios': RegExp(
    r'^((ios|darwin)/(?!(.*/)?(RunnerTests|xcuserdata)/)'
    r'(?!Flutter/(Generated\.xcconfig|flutter_export_environment\.sh|ephemeral/))'
    r'.*(?<!\.md)(?<!GeneratedPluginRegistrant\.[hm])$|hook/)',
  ),
};

Object? _nativeBuildInputs(Object? entry, String platform) => entry is! Map
    ? entry
    : {
        ...entry,
        'native_files': {
          for (final e in ((entry['native_files'] as Map?) ?? const {}).entries)
            if (_nativeBuildFiles[platform]!.hasMatch(e.key as String))
              e.key: e.value,
        },
      };

/// Compares package inputs with the release's [previous] ones. Native
/// changes become facts for the rules; each changed pure-Dart dependency is
/// recorded as changed. True if any pure-Dart dependency changed.
bool compareInputs(
  Map current,
  Map previous,
  String app,
  PatchFacts facts, {
  String platform = 'android',
}) {
  Map? inputs(Map state, String name) =>
      _nativeBuildInputs(state[name], platform) as Map?;
  facts.appNativeChanged =
      canonical(inputs(current, app)?['native_files']) !=
      canonical(inputs(previous, app)?['native_files']);
  var any = false;
  for (final name in {
    ...current.keys.cast<String>(),
    ...previous.keys.cast<String>(),
  }) {
    if (name == app) continue;
    final now = inputs(current, name), before = inputs(previous, name);
    if (canonical(now) == canonical(before)) continue;
    if (now?['native'] == true ||
        before?['native'] == true ||
        (now?['native_files'] as Map? ?? {}).isNotEmpty ||
        (before?['native_files'] as Map? ?? {}).isNotEmpty) {
      facts.nativeDependencies.add(name);
      continue;
    }
    any = true;
    facts.changed.add('dependency:$name');
  }
  return any;
}

/// One patch run: the request, its release and what the run has learned.
class PatchRun {
  PatchRun(this.pipeline, this.req, this.resolved, this.work)
    : facts = PatchFacts(resolved.strategy, req.platform, work);
  final PatchPipeline pipeline;
  final PatchRequest req;
  final ResolvedRelease resolved;
  final String work;
  final PatchFacts facts;
  final PatchRules rules = PatchRules();

  /// Tools reports of every module compiled.
  final List<Map<String, dynamic>> reports = [];
  String phase = 'baseline';

  /// The build copy of the project, its package config and package name.
  late final String project, config, app;
  Map<String, dynamic> get receipt => resolved.receipt;
}

/// What a strategy's code step hands to the shared rest of the pipeline.
class PatchCode {
  PatchCode({
    required this.kind,
    required this.file,
    required this.bundle,

    required this.fonts,
    this.metadata = const {},
    this.report = const {},
  });

  /// A key of [codePaths], and the file holding that code.
  final String kind, file;

  /// A flutter_assets directory built from the patch's sources.
  final String bundle;

  /// Collects the fonts the patch ships.
  final Future<void> Function(PatchResources) fonts;

  /// Extra signed manifest fields, and extra report fields.
  final Map<String, Object?> metadata, report;
}

/// A strategy's steps. Everything else a patch goes through is shared.
abstract class CodeProducer {
  /// Release checks before any work is done.
  Future<void> prepare();

  /// Input facts beyond the shared dependency comparison.
  Future<void> inputs(bool dependencyChanged);

  /// Builds the patch's code and a bundle of its resources.
  Future<PatchCode> produce();
}

/// The artifact releases [resolved]'s host was built with.
Iterable<ArtifactRelease> builtWith(ResolvedRelease resolved) {
  final recorded = resolved.receipt['artifacts'];
  require(
    recorded is Map && recorded.isNotEmpty,
    'BASELINE_ARTIFACTS_MISSING',
    'The host was built before its engine and tools releases were '
        'recorded; rebuild it with this flutter_patcher.',
  );
  return [
    for (final row in (recorded as Map).values) ArtifactRelease.fromJson(row),
  ];
}

class PatchPipeline {
  final Commands commands;
  final SdkIdentity sdk;
  final String managed, tool, cache;
  final BaselineRepository baselines;

  /// The engine release record; an SO patch rebuilds the host's APK with it.
  final Map<String, dynamic>? engine;
  PatchPipeline(
    this.commands,
    this.sdk,
    this.managed,
    this.tool,
    this.cache,
    this.baselines, {
    this.engine,
  });

  /// Builds [req]'s patch of the [resolved] release.
  Future<Map<String, Object?>> patch(
    PatchRequest req,
    ResolvedRelease resolved,
  ) async {
    await req.validate();
    for (final protected in [sdk.root, managed]) {
      require(
        !p.equals(p.absolute(protected), p.absolute(req.output)) &&
            !p.isWithin(p.absolute(protected), p.absolute(req.output)),
        'PATCH_CONFIG_INVALID',
        'Output cannot be inside a Flutter SDK',
      );
    }
    final work = await RunWork.create(p.join(cache, 'patches/run'));
    PatchRun? run;
    try {
      final receipt = resolved.receipt;
      require(
        req.minBuild.toString() == receipt['version_code'],
        'PATCH_BASELINE_INCOMPATIBLE',
        'Minimum build must match the target release',
      );

      final current = run = PatchRun(this, req, resolved, work);
      final producer = resolved.strategy == 'so'
          ? LibappProducer(current)
          : BytecodeProducer(current);
      await producer.prepare();
      trace('baseline');

      current.phase = 'sources';
      final workspace = BuildWorkspace(work);
      current.project = await workspace.copyPackage(
        req.project,
        application: true,
      );
      trace('copied project');
      await commands.run(sdk.host.flutterLauncher(managed), [
        '--suppress-analytics',
        'pub',
        'get',
        '--enforce-lockfile',
        if (req.offline) '--offline',
      ], cwd: current.project);
      current.config = p.join(
        current.project,
        '.dart_tool/package_config.json',
      );
      current.app =
          (loadYaml(
                await File(p.join(current.project, 'pubspec.yaml'))
                    .readAsString(),
              ) as Map)['name']
              as String;
      // The generated entry's package, read into package inputs as at build.
      await installRuntimePackage(
        current.config,
        current.app,
        req.target.substring(4),
      );
      final oldState = receipt['package_inputs'];
      require(
        oldState is Map,
        'PATCH_BASELINE_INCOMPATIBLE',
        'Baseline lacks dependency/native provenance; rebuild host',
      );
      final dependencyChanged = compareInputs(
        await packageInputs(current.config, application: current.app),
        oldState as Map,
        current.app,
        current.facts,
        platform: req.platform,
      );
      trace('package inputs');
      await producer.inputs(dependencyChanged);
      current.rules.check(PatchStage.inputs, current.facts);

      final code = await producer.produce();
      current.rules.check(PatchStage.code, current.facts);

      current.phase = 'resources';
      final payload = PatchResources(code.bundle, work, commands, managed);
      final oldResources = receipt['resources'];
      require(
        oldResources is Map,
        'PATCH_BASELINE_INCOMPATIBLE',
        'Baseline lacks resource inventory; rebuild host',
      );
      await payload.collect(
        Map<String, dynamic>.from(oldResources as Map),
        req.assets,
      );
      final facts = current.facts
        ..assets = [for (final row in payload.assets) row['key'] as String]
        ..deletedAssets = payload.deleted
        ..engineCapabilities = [
          for (final name
              in receipt['engine_capabilities'] as List? ?? const [])
            name as String,
        ];
      for (final key in facts.assets) {
        if (key != 'AssetManifest.bin') facts.changed.add('asset:$key');
      }
      await code.fonts(payload);
      // Font-only changes are meaningful even when all Dart hashes match.
      if (payload.fonts.isNotEmpty) {
        final oldFiles = oldResources['files'] as Map;
        final manifest = File(p.join(code.bundle, 'FontManifest.json'));
        if (await manifest.exists() &&
            await hashFile(manifest.path) !=
                oldFiles['FontManifest.json']?['sha256']) {
          facts.changed.add('fonts');
        }
        for (final key in await readObjectFontSources(code.bundle)) {
          if (await hashFile(p.join(code.bundle, key)) !=
              oldFiles[key]?['sha256']) {
            facts.changed.add('font:$key');
          }
        }
      }
      await _scan(current, payload);
      current.rules.check(PatchStage.resources, facts);
      current.rules.check(PatchStage.result, facts);

      current.phase = 'package';
      final draft = await packPatch(
        kind: code.kind,
        code: code.file,
        extraEntries: payload.entries,
        fonts: payload.fonts,
        assets: payload.assets,
        metadata: {
          'patch_seq': req.seq,
          'fingerprint': resolved.fingerprint,
          ...code.metadata,
          'flutter_version': sdk.version,
          'engine_commit': sdk.engine,
          'build_id': resolved.buildId,
          // Signed: publication accepts the patch for this release only.
          if (resolved.target != null) 'target': resolved.target,
        },
      );
      await workspace.verifyOriginals();
      await baselines.recheck(resolved, sdkRoot: sdk.root);
      final so = resolved.strategy == 'so';
      final policy = HostPolicy.parse(
        await File(
          p.join(
            so ? resolved.releaseRoot : resolved.compileRoot,
            'host_policy.json',
          ),
        ).readAsString(),
      );
      final output = await writeOutput(req, draft, {
        'status': 'patch_created',
        // What publish signs this patch for.
        'scope': {
          for (final key in TrustUpdate.scopeKeys)
            key: key == 'fingerprint'
                ? resolved.fingerprint
                : policy.fields[key],
        },
        'platform': req.platform,
        'abi': req.abi,
        'strategy': resolved.strategy,
        'fingerprint': resolved.fingerprint,
        'patch_seq': req.seq,
        'min_build': req.minBuild,
        ...code.report,
        'changed': facts.changed,
        if (current.rules.warnings.isNotEmpty)
          'warnings': current.rules.warnings,
        'draft_sha256': draft.digest,
        'bytes': draft.payload.length,
        if (!so) 'checks': current.reports,
        'device_verified': false,
        'release_baseline_verified': true,
        'release': resolved.report,
        'baseline_cache': {
          if (!so) 'compile': resolved.compileRoot,
          'release': resolved.releaseRoot,
        },
      });
      await RunWork.finish(work);
      return output;
    } catch (error) {
      final phase = run?.phase ?? 'baseline';
      await writeObject(p.join(work, 'failure.json'), {
        'phase': phase,
        'code': error is Failure ? error.code : error.runtimeType.toString(),
      });
      if (error is Failure) {
        throw PatchFailure(error.code, error.message, {
          'phase': phase,
          'work': work,
          if (run != null) 'checks': run.reports,
          if (run != null && run.rules.warnings.isNotEmpty)
            'warnings': run.rules.warnings,
        });
      }
      rethrow;
    }
  }

  /// Facts of the boundary warnings: read only when the patch changes code
  /// or assets, which is when they apply.
  Future<void> _scan(PatchRun run, PatchResources payload) async {
    final facts = run.facts;
    final sizes = [
      for (final e in payload.entries.entries) (e.key, e.value.length),
    ]..sort((a, b) => b.$2.compareTo(a.$2));
    facts
      ..resourceBytes = sizes.fold(0, (n, r) => n + r.$2)
      ..largestResources = sizes.take(3).toList();
    final assets = facts.changedAssets;
    if (assets.isEmpty && !facts.codeChanged) return;
    final scan = SourceScan(
      await packageRoots(run.config),
      run.app,
      sdkRoots: [sdk.root, managed],
    );
    if (assets.isNotEmpty) {
      facts.nativeAssetReaders = await scan.nativeAssetReaders(
        run.req.platform,
      );
      facts.assetsPassed = await scan.assetsPassedTo(
        facts.nativeAssetReaders.keys,
        assets,
      );
    }
    final background = await scan.backgroundEntries();
    facts
      ..backgroundEntries = background.entries
      ..backgroundRegistrations = background.registrations;
    trace('source scan');
  }

  /// Writes the draft and report into the request's new output directory.
  Future<Map<String, Object?>> writeOutput(
    PatchRequest req,
    PatchDraft draft,
    Map<String, Object?> report,
  ) async {
    final pending = temporaryName(p.absolute(req.output));
    await Directory(pending).create(recursive: true);
    await draft.write(pending);
    await writeObject(p.join(pending, 'patch.json'), report);
    await rejectLinks(req.output);
    require(
      await FileSystemEntity.type(req.output, followLinks: false) ==
          FileSystemEntityType.notFound,
      'PATCH_CONFIG_INVALID',
      'Output appeared during compilation',
    );
    await Directory(pending).renameRetry(p.absolute(req.output));
    return {...report, 'output': p.absolute(req.output)};
  }
}
