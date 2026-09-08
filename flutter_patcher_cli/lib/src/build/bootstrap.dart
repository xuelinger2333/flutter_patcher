import 'dart:convert';
import '../core.dart';

String bootstrapSource(
    String package, String entry, String fingerprint, String key) {
  require(
      RegExp(r'^[a-zA-Z_][a-zA-Z_0-9]*$').hasMatch(package) &&
          RegExp(r'^[0-9a-f]{64}$').hasMatch(fingerprint),
      'BUILD_CONFIG_INVALID',
      'Invalid bootstrap identity.');
  List<int> bytes;
  try {
    bytes = base64Decode(key);
  } catch (_) {
    throw Failure(
        'BUILD_CONFIG_INVALID', 'Public key must be raw Ed25519 base64.');
  }
  require(bytes.length == 32, 'BUILD_CONFIG_INVALID',
      'Public key must contain 32 bytes.');
  return "import 'package:flutter_patcher/flutter_patcher.dart';\n"
      'import ${jsonEncode('package:$package/$entry').replaceAll(r'$', r'\$')} as app;\n'
      'const _fingerprint = ${jsonEncode(fingerprint)};\n'
      'const _publicKey = ${jsonEncode(key)};\n'
      'Future<void> main() => PatchBootstrap.run(original: app.main,\n'
      '  fingerprint: _fingerprint, publicKeyBase64: _publicKey);\n';
}
