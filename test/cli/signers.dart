import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'package:flutter_patcher/src/cli/crypto/ed25519.dart';
import 'package:flutter_patcher/src/cli/keys/bundle.dart';
import 'package:flutter_patcher/src/cli/keys/signer.dart';

/// A [role] signer of a test seed.
Signer testSigner(String seed, [KeyRole role = KeyRole.publisher]) =>
    SeedSigner(role, base64Decode(seed), 'test');

/// Makes [project] a project whose root, publisher and patch keys are all
/// [seed]'s: its flutter_patcher.yaml names the public key, and the returned
/// key bundle file holds the seed for each role.
Future<String> writeTestKeys(
  String project,
  String seed, {
  String? store,
  String? baselineStore,
}) async {
  final raw = base64Decode(seed);
  final bundle = KeyBundle({for (final role in KeyRole.values) role: raw});
  final public = bundle.publicKey(KeyRole.root);
  await Directory(project).create(recursive: true);
  await File(p.join(project, 'flutter_patcher.yaml')).writeAsString(
    "${store == null ? '' : "store: '$store'\n"}"
    "${baselineStore == null ? '' : "baseline_store: '$baselineStore'\n"}"
    'trust:\n  root: $public\n  publisher: $public\n  patch: $public\n',
  );
  final file = p.join(project, 'test-keys.json');
  await File(file).writeAsString(bundle.encode());
  return file;
}

/// Signs [message] with a base64 [seed], checking it is [public]'s.
Uint8List signMessage(List<int> message, String seed, String public) {
  final raw = base64Decode(seed.trim());
  if (base64Encode(ed25519PublicKey(raw)) != public.trim()) {
    throw ArgumentError('The seed is not the key of $public');
  }
  return ed25519Sign(raw, message);
}
