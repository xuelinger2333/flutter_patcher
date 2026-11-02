import '../core.dart';
import 'resources.dart';

/// When a rule's facts are known. The pipeline checks each stage as soon as it
/// reaches it, so a rejection never waits for a later, slower step.
enum PatchStage {
  /// Sources and dependencies compared with the release.
  inputs,

  /// One compiled module (a bytecode patch may compile twice).
  compile,

  /// The code the patch ships.
  code,

  /// The resources the patch ships.
  resources,

  /// The whole patch.
  result
}

/// What the pipeline has learned about a patch; rules read it.
class PatchFacts {
  PatchFacts(this.strategy, this.platform, this.evidence);
  final String strategy, platform;

  /// Work directory, quoted in messages as evidence.
  final String evidence;

  /// The application's own native files changed since the release.
  bool appNativeChanged = false;

  /// Dependencies whose native capability or native files changed.
  final List<String> nativeDependencies = [];

  /// Plugins whose Dart sources changed (bytecode).
  final List<String> changedPlugins = [];

  /// Packages pinned since the release that it did not pin (bytecode).
  final List<String> newlyPinned = [];

  /// Changed pinned packages: name -> why pinned, and the release's version.
  final Map<String, ({String why, Object? version})> changedPinned = {};

  /// The tools report of the module just compiled, or of the final one.
  Map<String, dynamic>? report;

  /// `lean` or `whole` (bytecode).
  String? tier;

  /// Engine patches the host was built with.
  List<String> enginePatches = const [];

  /// Asset keys the patch carries, and those the release has but it lacks.
  List<String> assets = const [], deletedAssets = const [];

  /// Everything the patch changes; empty means there is nothing to ship.
  final List<String> changed = [];
}

class PatchRule {
  const PatchRule(this.code, this.stage, this.findings,
      {this.strategies = const {'bytecode', 'so'}, this.reject = true});

  /// The failure code a rejection carries, or the code of a warning.
  final String code;
  final PatchStage stage;
  final Set<String> strategies;

  /// False for a warning: the patch ships, and the report says why to look.
  final bool reject;

  /// One message per finding.
  final List<String> Function(PatchFacts facts) findings;
}

/// Every boundary a patch is held to. A rule here is the only place its
/// condition is decided; producers only gather facts.
final patchRules = <PatchRule>[
  PatchRule(
      'PATCH_NATIVE_CHANGE',
      PatchStage.inputs,
      (f) => [
            if (f.appNativeChanged)
              'Application native sources changed; rebuild host',
            for (final name in f.nativeDependencies)
              'Native plugin/build hook changed: $name',
            for (final name in f.changedPlugins)
              'Native plugin changes require a new host release: $name',
            if (f.newlyPinned.isNotEmpty)
              'Packages with native capability, or reached from one, are new '
                  'since the release and need a new host release: '
                  '${f.newlyPinned.join(', ')}',
          ]),
  PatchRule(
      'PATCH_PINNED_PACKAGE_CHANGED',
      PatchStage.inputs,
      (f) => [
            for (final e in f.changedPinned.entries)
              '${e.key} stays in the host (${e.value.why}), so a patch cannot '
                  'change it; a new host release can. To keep the release\'s copy'
                  '${e.value.version == null ? '' : ', add to pubspec.yaml:\n'
                      'dependency_overrides:\n  ${e.key}: ${e.value.version}'}',
          ],
      strategies: const {'bytecode'}),
  // The interpreter cannot make FFI calls in an AOT runtime: a module with
  // one would abort the app, whichever tier carried it.
  PatchRule('PATCH_FFI_UNSUPPORTED', PatchStage.compile, (f) {
    final sites = (f.report?['checks'] as Map?)?['ffi'];
    if (sites is! List || sites.isEmpty) return const [];
    final first = sites.first as Map;
    return [
      'Patched code would run FFI in the interpreter (${first['message']} at '
          '${first['file']}:${first['line']}). Keep FFI in unchanged host code, '
          'which a patch may call, or ship a new host release.'
    ];
  }, strategies: const {'bytecode'}),
  PatchRule(
      'PATCH_UNSAFE',
      PatchStage.code,
      (f) => [
            if (f.report?['status'] != 'compiled')
              '${f.tier == 'lean' ? 'Lean' : 'Whole'}-tier checks failed: '
                  '${checkSummary(f.report ?? const {})}; evidence: ${f.evidence}',
          ],
      strategies: const {'bytecode'}),
  // A patch's icon font is subset to the constant IconData it uses.
  PatchRule(
      'PATCH_DYNAMIC_ICON',
      PatchStage.code,
      (f) => [
            if ((f.report?['dynamic_fonts'] as List? ?? const []).isNotEmpty)
              'Non-constant IconData cannot be subset safely',
          ],
      strategies: const {'bytecode'}),
  // Patch assets lie in front of the host's; they cannot remove one.
  PatchRule(
      'PATCH_ASSET_DELETE_UNSUPPORTED',
      PatchStage.resources,
      (f) => [
            for (final key in f.deletedAssets)
              'Resource deletion requires a new host: $key',
          ]),
  // The engine installs patch assets in front of the app bundle; under an
  // engine without that patch every boot of this patch would fail.
  PatchRule(
      'PATCH_ENGINE_UNSUPPORTED',
      PatchStage.resources,
      (f) => [
            if (f.assets.isNotEmpty &&
                !f.enginePatches.contains(engineAssetChannelPatch))
              'Asset changes need a host whose engine installs patch assets '
                  '($engineAssetChannelPatch); rebuild the host with the current '
                  'engine, or ship the assets in a host release',
          ]),
  PatchRule(
      'PATCH_NO_CHANGES',
      PatchStage.result,
      (f) => [
            if (f.changed.isEmpty)
              'No Dart, dependency or resource changes detected',
          ]),
];

/// Applies [rules] stage by stage: the first rejection throws, warnings
/// accumulate for the report.
class PatchRules {
  PatchRules([List<PatchRule>? rules]) : rules = rules ?? patchRules;
  final List<PatchRule> rules;
  final List<Map<String, String>> warnings = [];

  void check(PatchStage stage, PatchFacts facts) {
    for (final rule in rules) {
      if (rule.stage != stage || !rule.strategies.contains(facts.strategy)) {
        continue;
      }
      for (final message in rule.findings(facts)) {
        if (rule.reject) throw Failure(rule.code, message);
        warnings.add({'code': rule.code, 'message': message});
      }
    }
  }

  /// The rule table, for documentation and the report.
  static List<Map<String, Object>> describe() => [
        for (final r in patchRules)
          {
            'code': r.code,
            'stage': r.stage.name,
            'strategies': r.strategies.toList()..sort(),
            'severity': r.reject ? 'reject' : 'warn'
          }
      ];
}

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
