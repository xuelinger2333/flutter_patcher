import 'dart:convert';

import '../core.dart';

/// The generated main of a host: it runs [PatchBootstrap] before the app's
/// own main. A bytecode host also retains the runtime that loads modules;
/// an SO host ([modules] false) runs a patch as its whole libapp.so and only
/// receives the patch's resources.
///
/// It also declares what an engine with the patcher entry hook asks for
/// every other entry point: `flutterPatcherEntry`, which boots a background
/// isolate the same way, and the app's entry library, where entry points
/// named without a library are found.
String bootstrapSource(
  String package,
  String entry,
  String fingerprint,
  String key, {
  bool modules = true,
}) {
  require(
    RegExp(r'^[a-zA-Z_][a-zA-Z_0-9]*$').hasMatch(package) &&
        RegExp(r'^[0-9a-f]{64}$').hasMatch(fingerprint),
    'BUILD_CONFIG_INVALID',
    'Invalid bootstrap identity.',
  );
  List<int> bytes;
  try {
    bytes = base64Decode(key);
  } catch (_) {
    throw Failure(
      'BUILD_CONFIG_INVALID',
      'Public key must be raw Ed25519 base64.',
    );
  }
  require(
    bytes.length == 32,
    'BUILD_CONFIG_INVALID',
    'Public key must contain 32 bytes.',
  );
  final library = jsonEncode('package:$package/$entry').replaceAll(r'$', r'\$');
  final loader = modules ? ', loadModule: loadModule' : '';
  return "import 'package:flutter_patcher/flutter_patcher.dart';\n"
      '${modules ? "import 'package:dynamic_modules/dynamic_modules.dart';\n"
                "import 'package:dynamic_modules/host.dart' as host;\n" : ''}'
      'import $library as app;\n'
      'const _fingerprint = ${jsonEncode(fingerprint)};\n'
      'const _publicKey = ${jsonEncode(key)};\n'
      'Future<void> main() { ${modules ? 'host.retainRuntime(); ' : ''}'
      'return PatchBootstrap.run(original: app.main,\n'
      '  fingerprint: _fingerprint, publicKeyBase64: _publicKey$loader); }\n'
      "@pragma('vm:entry-point')\n"
      'const flutterPatcherAppLibrary = $library;\n'
      "@pragma('vm:entry-point')\n"
      'Function? flutterPatcherEntry(String key, Function? original, bool start) =>\n'
      '    PatchBootstrap.entry(key, original, start: start,\n'
      '        fingerprint: _fingerprint, publicKeyBase64: _publicKey$loader);\n';
}
