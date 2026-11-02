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
  /// Not build inputs: VCS, caches, outputs, per-user IDE state (Xcode
  /// rewrites xcuserdata while the project is open), CocoaPods output that
  /// Flutter regenerates (ios/.symlinks and Pods hold symbolic links) and
  /// Flutter's per-platform `ephemeral` directories (desktop ones hold
  /// .plugin_symlinks; all are rewritten on pub get and build).
  static const excluded = {
    '.git',
    '.dart_tool',
    '.gradle',
    'build',
    '.idea',
    'xcuserdata',
    '.symlinks',
    'Pods',
    'ephemeral',
    '.DS_Store'
  };
  /// Where Flutter, Gradle and CocoaPods put each excluded name; elsewhere
  /// (e.g. lib/features/build/) the name is an ordinary source directory.
  static const _placed = {
    'build': {'', 'android', 'android/app', 'ios', 'macos', 'linux', 'windows'},
    'Pods': {'ios', 'macos'},
    '.symlinks': {'ios', 'macos'},
    'ephemeral': {'ios/Flutter', 'macos/Flutter', 'linux/flutter', 'windows/flutter'},
  };

  /// Whether [relative] (a POSIX path from the package root) is excluded.
  static bool skipped(String relative) {
    final name = p.posix.basename(relative);
    if (!excluded.contains(name)) return false;
    final placed = _placed[name];
    if (placed == null) return true;
    final parent = p.posix.dirname(relative);
    return placed.contains(parent == '.' ? '' : parent);
  }

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
        final relative =
            p.relative(entry.path, from: original).replaceAll('\\', '/');
        if (skipped(relative)) continue;
        if (entry is Directory) {
          rejectCaseVariant(
              p.basename(entry.path),
              excluded.where((name) => skipped(
                  p.posix.join(p.posix.dirname(relative), name))),
              'BUILD_PROJECT_INVALID');
        }
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
    if (application) {
      for (final entry in copies.entries) {
        final lock = File(p.join(entry.value, 'pubspec.lock'));
        if (!await lock.exists()) continue;
        final data =
            jsonDecode(jsonEncode(loadYaml(await lock.readAsString()))) as Map;
        var changed = false;
        for (final row in (data['packages'] as Map).values) {
          if (row['source'] != 'path') continue;
          final description = row['description'] as Map;
          final path = p.normalize(
              p.absolute(p.join(entry.key, description['path'] as String)));
          final mapped = copies[path];
          require(mapped != null, 'BUILD_PROJECT_INVALID',
              'Locked path dependency was not copied');
          description['path'] = mapped;
          description['relative'] = false;
          changed = true;
        }
        if (changed) await lock.writeAsString('${jsonEncode(data)}\n');
      }
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
      await Directory(path).renameRetry(temporaryName('$path.retired'));
    }
  }
}
