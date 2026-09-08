import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';
import '../core.dart';

/// Flutter/Gradle may rewrite local.properties and generated plugin metadata.
/// Run them only against copies, including recursively copied path dependencies.
class BuildWorkspace {
  final String root;
  final Map<String, String> copies = {}, originalHashes = {};
  int bytes = 0;
  BuildWorkspace(this.root);
  static const excluded = {'.git', '.dart_tool', '.gradle', 'build', '.idea'};
  Future<String> copyPackage(String original,
      {bool application = false}) async {
    original = p.normalize(p.absolute(original));
    if (copies.containsKey(original)) return copies[original]!;
    require(await File(p.join(original, 'pubspec.yaml')).exists(),
        'BUILD_PROJECT_INVALID', 'Missing package pubspec.');
    final destination =
        p.join(root, application ? 'project' : 'dependencies/${copies.length}');
    copies[original] = destination;
    Future<void> copy(String from, String to) async {
      await rejectLinks(from);
      await Directory(to).create(recursive: true);
      await for (final entry in Directory(from).list(followLinks: false)) {
        if (excluded.contains(p.basename(entry.path))) continue;
        final target = p.join(to, p.basename(entry.path));
        if (entry is Directory) {
          await copy(entry.path, target);
        } else if (entry is File) {
          bytes += await entry.length();
          require(bytes <= 2 * 1024 * 1024 * 1024, 'BUILD_PROJECT_INVALID',
              'Source copy exceeds 2 GiB.');
          originalHashes[entry.path] = await hashFile(entry.path);
          await entry.copy(target);
        } else {
          throw Failure('BUILD_PROJECT_INVALID',
              'Symbolic links in source packages are unsupported: ${entry.path}');
        }
      }
    }

    await copy(original, destination);
    for (final name in ['pubspec.yaml', 'pubspec_overrides.yaml']) {
      final pubspec = File(p.join(destination, name));
      if (!await pubspec.exists()) continue;
      final data =
          jsonDecode(jsonEncode(loadYaml(await pubspec.readAsString())))
              as Map<String, dynamic>;
      var changed = false;
      for (final section in [
        'dependencies',
        'dev_dependencies',
        'dependency_overrides'
      ]) {
        final deps = data[section];
        if (deps is! Map) continue;
        for (final value in deps.values) {
          if (value is Map && value['path'] is String) {
            final dependency =
                p.normalize(p.join(original, value['path'] as String));
            value['path'] = await copyPackage(dependency);
            changed = true;
          }
        }
      }
      if (changed) await pubspec.writeAsString('${jsonEncode(data)}\n');
    }
    return destination;
  }

  Future<void> verifyOriginals() async {
    for (final entry in originalHashes.entries) {
      require(
          await File(entry.key).exists() &&
              await hashFile(entry.key) == entry.value,
          'BUILD_INPUT_CHANGED',
          'Source input changed during build: ${entry.key}');
    }
  }
}

Future<void> retireFlutterGradleCache(String home) async {
  await rejectLinks(home);
  final modules = p.join(home, 'caches/modules-2');
  final paths = [p.join(modules, 'files-2.1/io.flutter')];
  if (await Directory(modules).exists()) {
    await for (final entry in Directory(modules).list(followLinks: false)) {
      if (entry is Directory &&
          p.basename(entry.path).startsWith('metadata-')) {
        paths.add(p.join(entry.path, 'descriptors/io.flutter'));
      }
    }
  }
  for (final path in paths) {
    await rejectLinks(path);
    if (await Directory(path).exists()) {
      await Directory(path).rename(temporaryName('$path.retired'));
    }
  }
}
