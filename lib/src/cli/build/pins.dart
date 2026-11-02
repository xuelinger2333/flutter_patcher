import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';
import '../core.dart';

/// The packages a patch never carries: it always uses the host's copy.
///
/// A package is pinned when it has native capability (an FFI import, a
/// Flutter plugin, a build hook) or is reachable from one along dependency
/// edges: the host compiled those against exactly these copies, and a patch
/// copy of a dependency would give the types crossing their APIs a second
/// identity. Flutter is pinned by the same rule (every plugin depends on it)
/// and explicitly. Everything else the application depends on is free: the
/// whole tier renames it into the patch.
class PackagePins {
  /// Pinned package -> why: its own reason, or the dependency path from the
  /// package that pulled it in (`firebase_core -> http -> crypto`).
  final Map<String, Map<String, Object>> pinned;

  /// Packages the application depends on (transitively) that are not pinned.
  final Set<String> free;

  PackagePins(this.pinned, this.free);
}

Future<PackagePins> computePackagePins(String config, String app) async {
  final data = await readObject(config);
  final roots = <String, Directory>{};
  for (final row in data['packages'] as List) {
    final uri = File(config).absolute.uri.resolve(
        '${(row['rootUri'] as String).replaceFirst(RegExp(r'/+$'), '')}/');
    roots[row['name'] as String] = Directory.fromUri(uri);
  }
  require(roots.containsKey(app), 'BUILD_PROJECT_INVALID',
      'Application package is missing from the package config');
  final pubspecs = <String, Map>{};
  Future<Map> pubspec(String name) async {
    if (pubspecs[name] case final cached?) return cached;
    final file = File(p.join(roots[name]!.path, 'pubspec.yaml'));
    final value =
        await file.exists() ? loadYaml(await file.readAsString()) : null;
    return pubspecs[name] = value is Map ? value : const {};
  }

  Future<List<String>> dependencies(String name) async {
    final deps = (await pubspec(name))['dependencies'];
    return deps is Map
        ? [
            for (final d in deps.keys.cast<String>().toList()..sort())
              if (roots.containsKey(d)) d
          ]
        : const [];
  }

  // Runtime dependencies of the application only (dev dependencies never
  // reach the host program).
  final reachable = <String>{};
  final queue = [app];
  while (queue.isNotEmpty) {
    for (final d in await dependencies(queue.removeAt(0))) {
      if (d != app && reachable.add(d)) queue.add(d);
    }
  }
  Future<String?> nativeReason(String name) async {
    if (name == 'flutter' || name == 'sky_engine') return 'framework';
    final flutter = (await pubspec(name))['flutter'];
    if (flutter is Map && flutter['plugin'] != null) return 'plugin';
    if (await File(p.join(roots[name]!.path, 'hook', 'build.dart')).exists()) {
      return 'build hook';
    }
    final lib = Directory(p.join(roots[name]!.path, 'lib'));
    if (await lib.exists()) {
      final ffi = RegExp(r'''^\s*(import|export)\s+['"]dart:ffi['"]''',
          multiLine: true);
      await for (final file in lib.list(recursive: true, followLinks: false)) {
        if (file is File &&
            file.path.endsWith('.dart') &&
            ffi.hasMatch(await file.readAsString())) {
          return 'ffi';
        }
      }
    }
    return null;
  }

  final pinned = <String, Map<String, Object>>{};
  final via = <String, List<String>>{};
  final sorted = reachable.toList()..sort();
  for (final name in sorted) {
    final reason = await nativeReason(name);
    if (reason == null) continue;
    pinned[name] = {'reason': reason};
    via[name] = [name];
  }
  // Breadth first from every seed, in name order: each pulled-in package
  // records one shortest path, deterministically.
  final frontier = [...via.keys];
  while (frontier.isNotEmpty) {
    final next = <String>[];
    for (final name in frontier) {
      for (final d in await dependencies(name)) {
        if (!reachable.contains(d) || via.containsKey(d)) continue;
        via[d] = [...via[name]!, d];
        pinned[d] = {'reason': 'dependency', 'via': via[d]!};
        next.add(d);
      }
    }
    frontier
      ..clear()
      ..addAll(next..sort());
  }
  return PackagePins(
      {for (final k in pinned.keys.toList()..sort()) k: pinned[k]!},
      reachable.difference(pinned.keys.toSet()));
}
