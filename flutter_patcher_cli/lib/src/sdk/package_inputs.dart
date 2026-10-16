import 'dart:io';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';
import '../core.dart';

/// Portable dependency identity, including native plugin sources unavailable
/// in the Dart kernel. Recorded at build time; patch cannot invent it later.
Future<Map<String, dynamic>> packageInputs(String config,
    {String? application}) async {
  final data = await readObject(config), inputs = <String, dynamic>{};
  for (final row in data['packages'] as List) {
    final root = File(config).absolute.uri.resolve(
        '${(row['rootUri'] as String).replaceFirst(RegExp(r'/+$'), '')}/');
    final spec = File.fromUri(root.resolve('pubspec.yaml'));
    require(await spec.exists(), 'PACKAGE_INPUT_INVALID',
        'Package pubspec is missing: ${row['name']}');
    final yaml = loadYaml(await spec.readAsString()) as Map;
    final portable = jsonDecode(jsonEncode(yaml)) as Map;
    for (final section in [
      'dependencies',
      'dev_dependencies',
      'dependency_overrides'
    ]) {
      final deps = portable[section];
      if (deps is Map) {
        for (final dep in deps.values) {
          if (dep is Map && dep['path'] is String) {
            dep['path'] = '<local-package>';
          }
        }
      }
    }
    final flutter = yaml['flutter'];
    final native = flutter is Map && flutter['plugin'] != null;
    final files = <String, String>{};
    for (final part in [
      if (native || row['name'] == application) ...[
        'android',
        'ios',
        'linux',
        'macos',
        'windows'
      ],
      'hook'
    ]) {
      final dir = Directory.fromUri(root.resolve('$part/'));
      if (!await dir.exists()) continue;
      Future<void> visit(Directory directory) async {
        await for (final file in directory.list(followLinks: false)) {
          // AGP writes machine-specific CMake caches after the host is built.
          // Only this generated Android root directory is excluded; CMakeLists
          // and native sources beneath src remain part of the package identity.
          if (part == 'android' &&
              p.equals(directory.path, dir.path) &&
              file is Directory &&
              p.basename(file.path) == '.cxx') {
            continue;
          }
          if ([
            'build',
            '.gradle',
            '.dart_tool',
            '.git',
            'local.properties',
            'GeneratedPluginRegistrant.java'
          ].contains(p.basename(file.path))) {
            continue;
          }
          require(file is! Link, 'PACKAGE_INPUT_INVALID',
              'Native package contains a symlink');
          if (file is Directory) {
            rejectCaseVariant(
                p.basename(file.path),
                const ['build', '.gradle', '.dart_tool', '.git', '.cxx'],
                'PACKAGE_INPUT_INVALID');
            await visit(file);
          }
          if (file is File) {
            files[p
                .relative(file.path, from: root.toFilePath())
                .replaceAll('\\', '/')] = await hashFile(file.path);
          }
        }
      }

      await visit(dir);
    }
    inputs[row['name'] as String] = {
      'pubspec_sha256':
          sha256.convert(utf8.encode(jsonEncode(portable))).toString(),
      'version': '${yaml['version']}',
      'native': native,
      'native_files': {for (final k in files.keys.toList()..sort()) k: files[k]}
    };
  }
  return inputs;
}
