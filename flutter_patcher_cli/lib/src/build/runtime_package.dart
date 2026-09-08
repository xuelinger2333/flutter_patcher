import 'dart:io';
import 'package:path/path.dart' as p;
import '../core.dart';

/// Only this SDK-whitelisted package may import the dynamic-module intrinsic.
/// Generated inside the isolated workspace; never edits the user's pubspec.
Future<void> installRuntimePackage(
    String configPath, String app, String entry) async {
  final config = await readObject(configPath);
  require(
      !(config['packages'] as List).any((r) => r['name'] == 'dynamic_modules'),
      'BUILD_CONFIG_INVALID',
      'dynamic_modules is reserved by the patch runtime');
  final root =
      Directory(p.join(p.dirname(configPath), 'flutter_patcher/runtime'));
  await Directory(p.join(root.path, 'lib')).create(recursive: true);
  await File(p.join(root.path, 'pubspec.yaml')).writeAsString(
      'name: dynamic_modules\nversion: 1.0.0\nenvironment:\n  sdk: ">=3.10.0 <4.0.0"\n');
  await File(p.join(root.path, 'lib/dynamic_modules.dart')).writeAsString(
      "import 'dart:_internal' as internal;\nimport 'dart:typed_data';\n"
      'Future<Object?> loadModule(Uint8List bytes) => internal.loadDynamicModule(bytes: bytes);\n');
  await File(p.join(root.path, 'lib/host.dart')).writeAsString(
      "import 'package:$app/$entry' as app;\n"
      "import 'package:flutter_patcher/src/patch_bootstrap.dart';\n"
      "import 'package:flutter_patcher/src/bootstrap/overlay.dart';\n"
      "import 'dynamic_modules.dart';\n"
      "@pragma('vm:entry-point')\n"
      'Object retainRuntime() => [PatchBootstrap.run, patcherWrap, patcherWholeBundle, patcherInstallAssets, loadModule];\n'
      'Future<void> main() { retainRuntime(); return Future<void>.sync(app.main); }\n');
  (config['packages'] as List).add({
    'name': 'dynamic_modules',
    'rootUri': root.absolute.uri.toString(),
    'packageUri': 'lib/',
    'languageVersion': '3.10'
  });
  await writeObject(configPath, config);
}
