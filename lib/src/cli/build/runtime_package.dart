import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import '../core.dart';

/// Only this SDK-whitelisted package may import the dynamic-module intrinsic.
/// Generated inside the isolated workspace; never edits the user's pubspec.
Future<void> installRuntimePackage(
  String configPath,
  String app,
  String entry,
) async {
  final config = await readObject(configPath);
  require(
    !(config['packages'] as List).any((r) => r['name'] == 'dynamic_modules'),
    'BUILD_CONFIG_INVALID',
    'dynamic_modules is reserved by the patch runtime',
  );
  final root = Directory(
    p.join(p.dirname(configPath), 'flutter_patcher/runtime'),
  );
  await Directory(p.join(root.path, 'lib')).create(recursive: true);
  await File(p.join(root.path, 'pubspec.yaml')).writeAsString(
    'name: dynamic_modules\nversion: 1.0.0\nenvironment:\n  sdk: ">=3.10.0 <4.0.0"\n',
  );
  await File(p.join(root.path, 'lib/dynamic_modules.dart')).writeAsString(
    "import 'dart:_internal' as internal;\nimport 'dart:typed_data';\n"
    'Future<Object?> loadModule(Uint8List bytes) => internal.loadDynamicModule(bytes: bytes);\n',
  );
  await File(p.join(root.path, 'lib/host.dart')).writeAsString(
    "import 'package:$app/$entry' as app;\n"
    "import 'package:flutter_patcher/src/patch_bootstrap.dart';\n"
    "import 'dynamic_modules.dart';\n"
    "@pragma('vm:entry-point')\n"
    'Object retainRuntime() => [PatchBootstrap.run, loadModule];\n'
    'Future<void> main() { retainRuntime(); return Future<void>.sync(app.main); }\n',
  );
  (config['packages'] as List).add({
    'name': 'dynamic_modules',
    'rootUri': root.absolute.uri.toString(),
    'packageUri': 'lib/',
    'languageVersion': '3.10',
  });
  await writeObject(configPath, config);
}

/// Writes the generated host entry ([bootstrapSource]) into the runtime
/// package of the build copy [project] and returns it as the build target.
/// Inside the package it compiles as a package: URI; a file URI would embed
/// the run's work path in libapp.so.
Future<String> writeBootstrapEntry(String project, String source) async {
  final target = p.join(
    project,
    '.dart_tool/flutter_patcher/runtime/lib/main.dart',
  );
  await File(target).parent.create(recursive: true);
  await File(target).writeAsString(source);
  return target;
}

/// The `pub add` descriptor of the runtime package, relative to the build
/// copy. YAML, not JSON: a double quote does not survive Windows' flutter.bat.
const runtimeDependency =
    'dynamic_modules:{path: .dart_tool/flutter_patcher/runtime}';

/// Makes the runtime package of [installRuntimePackage] a dependency of the
/// build copy [project], which `flutter build` then keeps: its pub step
/// re-resolves a package_config naming a package the lockfile does not (Dart
/// 3.14), and that drops a package only the config has. [pub] runs pub in
/// [project]. Run after the build inputs are recorded: this edits the copy's
/// pubspec, which patches never see. Every other locked package stays.
Future<void> addRuntimeDependency(
  String project,
  Future<void> Function(List<String> arguments) pub,
) async {
  Future<String> locked() async {
    final lock = loadYaml(
      await File(p.join(project, 'pubspec.lock')).readAsString(),
    ) as Map;
    return jsonEncode(
      Map.of(lock['packages'] as Map? ?? const {})..remove('dynamic_modules'),
    );
  }

  final before = await locked();
  await pub(['add', '--offline', runtimeDependency]);
  require(
    await locked() == before,
    'BUILD_STEP_FAILED',
    'Adding the patch runtime package changed other locked packages.',
  );
}
