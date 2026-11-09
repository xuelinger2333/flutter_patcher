import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../core.dart';
import '../crypto/ed25519.dart';

/// A project's patch key, the one private key flutter_patcher uses: hosts
/// built with its public half accept only patch files it signed. One file
/// moves it between machines. flutter_patcher 1.0 bundles also hold root
/// and publisher keys; they are read past and never used.
final class KeyBundle {
  KeyBundle(this.seed) {
    require(
      seed.length == 32,
      'KEYS_BUNDLE_INVALID',
      'A key bundle holds a 32-byte Ed25519 seed.',
    );
  }

  static const format = 'flutter_patcher.keys.v1';

  final Uint8List seed;

  static KeyBundle generate() => KeyBundle(ed25519GenerateSeed());

  /// A bundle as [encode] writes it, or that JSON in base64 (as CI secrets
  /// usually hold it).
  static KeyBundle decode(String text) {
    final seed = _patchSeed(text);
    require(
      seed != null,
      'KEYS_BUNDLE_INVALID',
      'This key bundle holds no patch key.',
    );
    return KeyBundle(seed!);
  }

  /// The patch seed of a bundle, or null when it holds none (a 1.0 bundle
  /// of other keys).
  static Uint8List? _patchSeed(String text) {
    try {
      var source = text.trim();
      if (!source.startsWith('{')) source = utf8.decode(base64Decode(source));
      rejectDuplicateJsonKeys(source);
      final value = jsonDecode(source);
      if (value is! Map ||
          value.length != 2 ||
          value['format'] != format ||
          value['keys'] is! Map) {
        throw const FormatException();
      }
      final keys = value['keys'] as Map;
      if (!keys.keys.every(const {'root', 'publisher', 'patch'}.contains)) {
        throw const FormatException();
      }
      keys.values.forEach(_seed);
      return keys['patch'] == null ? null : _seed(keys['patch']);
    } on Failure {
      rethrow;
    } catch (_) {
      throw Failure(
        'KEYS_BUNDLE_INVALID',
        'Not a flutter_patcher key bundle ($format).',
      );
    }
  }

  static Uint8List _seed(Object? value) =>
      rawEd25519Key(value) ?? (throw const FormatException());

  /// The pre-1.0 layout `keys init` wrote: `<dir>/patch/private-key.base64`.
  static Future<KeyBundle> readDirectory(String directory) async {
    final file = File(p.join(directory, 'patch', 'private-key.base64'));
    await rejectLinks(file.path);
    require(
      await file.exists(),
      'KEYS_BUNDLE_INVALID',
      'No patch private key in $directory.',
    );
    try {
      return KeyBundle(_seed((await file.readAsString()).trim()));
    } catch (_) {
      throw Failure('KEYS_BUNDLE_INVALID', 'Invalid key file: ${file.path}');
    }
  }

  String encode() => jsonEncode({
    'format': format,
    'keys': {'patch': base64Encode(seed)},
  });

  /// The base64 Ed25519 public key hosts trust.
  String get publicKey => base64Encode(ed25519PublicKey(seed));
}

/// Where a user's key bundles live: `~/.flutter_patcher/keys`.
String keyStoreRoot({Map<String, String>? environment}) {
  final env = environment ?? Platform.environment;
  final home = env['HOME'] ?? env['USERPROFILE'];
  require(home != null, 'CONFIG_INVALID', 'HOME (or USERPROFILE) is not set.');
  return p.join(home!, '.flutter_patcher', 'keys');
}

/// The stored bundle of [patchKey], or null. Bundles are found by their
/// patch key, so flutter_patcher 1.0 directories (named by the root key)
/// are found too.
Future<KeyBundle?> loadKeyStore(String patchKey, {String? root}) async =>
    (await _stored(patchKey, root ?? keyStoreRoot()))?.bundle;

Future<({String path, KeyBundle bundle})?> _stored(
  String patchKey,
  String root,
) async {
  await rejectLinks(root);
  if (!await Directory(root).exists()) return null;
  await for (final entry in Directory(root).list(followLinks: false)) {
    if (entry is! Directory) continue;
    final path = p.join(entry.path, 'keys.json');
    await rejectLinks(path);
    if (!await File(path).exists()) continue;
    final Uint8List? seed;
    try {
      seed = KeyBundle._patchSeed(await File(path).readAsString());
    } on Failure catch (error) {
      throw Failure(error.code, '${error.message}: $path');
    }
    if (seed == null) continue;
    final bundle = KeyBundle(seed);
    if (bundle.publicKey == patchKey) return (path: path, bundle: bundle);
  }
  return null;
}

/// Stores [bundle] in the user's key store and returns its file; a bundle
/// already stored stays where it is.
Future<String> saveKeyStore(KeyBundle bundle, {String? root}) async {
  root ??= keyStoreRoot();
  final stored = await _stored(bundle.publicKey, root);
  if (stored != null) return stored.path;
  final id = sha256
      .convert(base64Decode(bundle.publicKey))
      .toString()
      .substring(0, 16);
  final directory = p.join(root, id);
  final path = p.join(directory, 'keys.json');
  await Directory(root).create(recursive: true);
  await claimPrivateDirectory(directory);
  await _writePrivate(path, bundle.encode());
  return path;
}

/// Creates [path] exclusively and readable by its owner only: mode 700 on
/// POSIX, an ACL for the current user alone on Windows. Fails if it exists.
Future<void> claimPrivateDirectory(String path) async {
  await rejectLinks(path);
  // mkdir is exclusive, unlike Directory.create: competing initializers cannot
  // both succeed. POSIX tools run by absolute path, so neither PATH nor a
  // planted binary decides how the directory is created.
  final claim = Platform.isWindows
      ? await Process.run('cmd', ['/c', 'mkdir', path])
      : await Process.run('/bin/mkdir', ['-m', '700', '--', path]);
  require(
    claim.exitCode == 0,
    'KEYS_OUTPUT_UNAVAILABLE',
    'Cannot exclusively create key directory (already exists or is not writable): $path',
  );
  if (Platform.isWindows) {
    final user = Platform.environment['USERNAME'];
    final acl = user == null
        ? null
        : await Process.run('icacls', [
            path,
            '/inheritance:r',
            '/grant:r',
            '$user:(OI)(CI)F',
          ]);
    require(
      acl != null && acl.exitCode == 0,
      'KEYS_PERMISSIONS_FAILED',
      'Cannot restrict key directory permissions: $path',
    );
  }
}

/// Writes a key bundle to the new file [path], mode 600 on POSIX before any
/// byte of it is written. Refuses to replace an existing file.
Future<void> writeNewKeyFile(String path, String text) async {
  await rejectLinks(path);
  final file = File(path);
  await file.parent.create(recursive: true);
  try {
    await file.create(exclusive: true);
  } on FileSystemException {
    throw Failure('KEYS_OUTPUT_EXISTS', 'Use a new file: $path');
  }
  await _protect(file);
  await file.writeAsString('$text\n', flush: true);
}

Future<void> _protect(File file) async {
  if (Platform.isWindows) return;
  // macOS chmod has no `--`; an absolute path cannot read as an option.
  final mode = await Process.run('/bin/chmod', ['600', p.absolute(file.path)]);
  require(
    mode.exitCode == 0,
    'KEYS_PERMISSIONS_FAILED',
    'Cannot protect private-key permissions.',
  );
}

/// Writes a secret file atomically, mode 600 on POSIX before any byte of it
/// is written.
Future<void> _writePrivate(String path, String text) async {
  final staging = File(temporaryName(path));
  await staging.create(exclusive: true);
  await _protect(staging);
  await staging.writeAsString('$text\n', flush: true);
  await staging.renameRetry(path);
}
