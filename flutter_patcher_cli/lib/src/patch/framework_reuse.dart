import 'dart:io';
import 'package:path/path.dart' as p;
import '../core.dart';
import 'framework_carry.dart';
import 'sources.dart';

/// WP-2.5 host framework reuse for whole-tier patches.
///
/// Experimental and off by default (`--framework-reuse`): the host reuse
/// surface failed the frozen host-cost gate, so the default remains the
/// two-tier lean / full-whole selection. Everything here is only reached when
/// the request opts in and the baseline carries a schema 4 partition.

/// Writes the whole-tier interface: `dart:` rows always, `package:flutter/`
/// rows only when the host reuse surface is to be honoured.
Future<void> writeWholeInterface(String path, Map interfaceYaml,
    {required bool includeFramework}) {
  return writeObject(path, {
    for (final section in interfaceYaml.keys)
      section as String: [
        for (final row in (interfaceYaml[section] as List? ?? []))
          if ((row['library'] as String).startsWith('dart:') ||
              (includeFramework &&
                  (row['library'] as String).startsWith('package:flutter/')))
            row
      ]
  });
}

/// Framework libraries the lean check needed (M0).
///
/// A lean rejection can happen before the framework libraries are emitted,
/// so `module_libraries` alone is not a complete description. Allocation and
/// interface diagnostics carry the authoritative library URI for each
/// cross-boundary framework use; collect those together with any libraries
/// the compiler reported explicitly.
Set<String> frameworkCandidates(Map<String, dynamic> firstReport) {
  final candidate = <String>{
    for (final uri in ((firstReport['module_libraries'] as List?) ?? const []))
      if (uri is String && uri.startsWith('package:flutter/')) uri
  };
  void collect(Object? value) {
    if (value is Map) {
      final uri = value['library'];
      if (uri is String && uri.startsWith('package:flutter/')) {
        candidate.add(uri);
      }
      for (final child in value.values) {
        collect(child);
      }
    } else if (value is List) {
      for (final child in value) {
        collect(child);
      }
    }
  }

  collect(firstReport['checks']);
  return candidate;
}

/// Decides whether M0 can be carried against the release partition.
class FrameworkReusePlan {
  /// Carriable libraries listed by the partition.
  final Set<String> available;

  /// M0 without host barrels (barrels declare nothing and are always host).
  final Set<String> effective;

  /// M0 members the partition does not allow to travel.
  final Set<String> missing;
  FrameworkReusePlan._(this.available, this.effective, this.missing);

  factory FrameworkReusePlan(
      Map<String, Object?>? partition, Set<String> candidate) {
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
    final effective =
        candidate.where((uri) => !hostBarrels.contains(uri)).toSet();
    final missing = effective.where((uri) => !available.contains(uri)).toSet();
    return FrameworkReusePlan._(available, effective, missing);
  }

  bool get carriable =>
      effective.isNotEmpty &&
      missing.isEmpty &&
      available.containsAll(effective);

  /// Diagnostic recorded under `upgrade.framework_reuse.reasons`.
  Map<String, Object?> notCarriable() {
    final libraries = missing.isEmpty ? effective : missing;
    return {
      'code': 'FRAMEWORK_NOT_CARRIABLE',
      'message':
          'Framework library set requires host declarations: ${libraries.join(', ')}',
      'libraries': libraries.toList()
    };
  }
}

/// Copies the selected framework libraries into the module as
/// `patch.<seq>.flutter_carry` and rewrites the business sources to import
/// the copies. Returns the carry package config, its package name and the
/// `framework_reuse` metadata block.
Future<Map<String, Object?>> carryFrameworkLibraries({
  required String partitionPath,
  required String sdkRoot,
  required String work,
  required String packagesConfig,
  required int seq,
  required Set<String> selected,
  required Set<String> available,
  required Iterable<String> own,
  required Map<String, String> names,
}) async {
  final carry = await prepareFrameworkCarry(
      partition: partitionPath,
      sdkRoot: sdkRoot,
      destination: p.join(work, 'module'),
      packagesConfig: packagesConfig,
      seq: seq,
      selected: selected);
  final rewrites = (carry['uri_rewrites'] as Map).cast<String, String>();
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
  return {
    'packages': carry['packages'],
    'package': carry['package'],
    'info': {
      'enabled': true,
      'partition_sha256': await hashFile(partitionPath),
      'carried': (carry['carried'] as List).cast<String>(),
      'host_bound_count': available.length - selected.length,
    },
  };
}

/// Proves on the artifact that only the planned framework copies are in the
/// module and no original `package:flutter` library leaked in.
Future<void> verifyReuseStructure({
  required Commands commands,
  required String dart,
  required String tool,
  required String work,
  required int seq,
  required String app,
  required String partitionPath,
  required String carryPackage,
  required Iterable<String> carried,
}) async {
  final structure = await commands.runResult(dart, [
    tool,
    'verify-structure',
    '--bytecode',
    p.join(work, 'module.bc'),
    '--expect-prefix',
    'package:patch.$seq.',
    '--forbid-prefix',
    'package:$app/',
    '--framework-reuse',
    partitionPath,
    '--carry-package',
    'package:$carryPackage',
    '--expected-carried',
    carried.join(','),
  ]);
  await File(p.join(work, 'structure.log'))
      .writeAsString('${structure.stdout}\n${structure.stderr}');
  require(structure.exitCode == 0, 'PATCH_TOOL_FAILED',
      'Structure check failed to run; evidence: $work');
  await File(p.join(work, 'structure.json')).writeAsString(structure.stdout);
  final verdict = await readObject(p.join(work, 'structure.json'));
  require(verdict['ok'] == true, 'PATCH_UNSAFE',
      'Framework reuse structure check failed; evidence: $work');
}
