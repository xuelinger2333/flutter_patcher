import 'dart:convert';
import 'dart:io';
import 'package:args/args.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import '../core.dart';
import '../crypto/ed25519.dart';
import '../sdk/host.dart';

ArgParser keysOptions() => ArgParser()
  ..addFlag('help', abbr: 'h', negatable: false)
  ..addFlag('json', negatable: false, help: 'Output contains metadata only.')
  ..addOption('out',
      help: 'New key directory; default ~/.flutter_patcher/keys.');

Future<int> keysCommand(ArgResults args) async {
  require(args.rest.length == 1 && args.rest.single == 'init', 'USAGE_ERROR',
      'Use keys init [--out <new-directory>].');
  final host = requireSupportedHost();
  final home = hostHome();
  require(args['out'] != null || home != null && home.isNotEmpty,
      'KEYS_CONFIG_INVALID', 'Specify --out when HOME is unavailable.');
  final out = p.normalize(p.absolute(
      args['out'] as String? ?? p.join(home!, '.flutter_patcher', 'keys')));
  await rejectLinks(out);
  require(
      await FileSystemEntity.type(out, followLinks: false) ==
          FileSystemEntityType.notFound,
      'KEYS_OUTPUT_EXISTS',
      'Refusing to overwrite an existing key directory: $out');
  // The seed never leaves this process except as the base64 private-key file.
  final seed = ed25519GenerateSeed();
  final public = ed25519PublicKey(seed);
  require(ed25519Verify(public, ed25519Sign(seed, const [0]), const [0]),
      'KEYS_CRYPTO_FAILED', 'Generated key pair failed its self-check.');
  await Directory(p.dirname(out)).create(recursive: true);
  await rejectLinks(out);
  // mkdir is exclusive, unlike Directory.create: competing initializers cannot
  // both succeed. On POSIX mode 700 is applied at creation, before any secret
  // is written; on Windows the directory is created exclusively by cmd's
  // built-in mkdir and then its ACL is cut down to the current user.
  final claim = host.isWindows
      ? await Process.run('cmd', ['/c', 'mkdir', out])
      : await Process.run('mkdir', ['-m', '700', '--', out]);
  require(claim.exitCode == 0, 'KEYS_OUTPUT_UNAVAILABLE',
      'Cannot exclusively create key directory (already exists or is not writable): $out');
  if (host.isWindows) {
    final user = Platform.environment['USERNAME'];
    final acl = user == null
        ? null
        : await Process.run(
            'icacls', [out, '/inheritance:r', '/grant:r', '$user:(OI)(CI)F']);
    require(acl != null && acl.exitCode == 0, 'KEYS_PERMISSIONS_FAILED',
        'Cannot restrict key directory permissions: $out');
  }
  final privateFile = File(p.join(out, 'private-key.base64'));
  final publicFile = File(p.join(out, 'public-key.base64'));
  final ignoreFile = File(p.join(out, '.gitignore'));
  try {
    await privateFile.create();
    if (host.isPosix) {
      final mode = await Process.run('chmod', ['600', '--', privateFile.path]);
      require(mode.exitCode == 0, 'KEYS_PERMISSIONS_FAILED',
          'Cannot protect private-key permissions.');
    }
    await privateFile.writeAsString('${base64Encode(seed)}\n', flush: true);
    await publicFile.writeAsString('${base64Encode(public)}\n', flush: true);
    await ignoreFile.writeAsString('private-key.base64\n', flush: true);
    stdout.writeln(jsonEncode({
      'command': 'keys init',
      'status': 'keys_created',
      'algorithm': 'Ed25519',
      'private_key_format': 'base64-raw32-seed',
      'public_key_format': 'base64-raw32',
      'directory': out,
      'private_key': privateFile.path,
      'public_key': publicFile.path,
      'public_key_sha256': sha256.convert(public).toString()
    }));
    return 0;
  } catch (_) {
    // Only our known files; never recursively delete an output directory.
    for (final file in [privateFile, publicFile, ignoreFile]) {
      if (await file.exists()) await file.deleteRetry();
    }
    try {
      await Directory(out).deleteRetry();
    } on FileSystemException {/* Retain foreign files. */}
    rethrow;
  }
}
