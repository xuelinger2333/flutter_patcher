import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../core.dart';
import '../crypto/ed25519.dart';

/// The three key pairs of a project. Their public halves are built into every
/// host; their private halves sign what devices accept.
enum KeyRole {
  root('signs trust updates; keep it offline'),
  publisher('signs publications'),
  patch('signs patch envelopes; fixed for every shipped host');

  const KeyRole(this.purpose);
  final String purpose;
}

/// The public keys a project's hosts trust. They live in flutter_patcher.yaml
/// and are committed; nothing here is secret.
final class TrustAnchors {
  TrustAnchors({
    required this.root,
    required this.publisher,
    required this.patch,
  }) {
    for (final role in KeyRole.values) {
      require(
        _isPublicKey(of(role)),
        'KEYS_NOT_CONFIGURED',
        'The ${role.name} public key is not a base64 Ed25519 key.',
      );
    }
  }

  /// The keys of a host policy: its root and patch keys, and the publisher
  /// key it was built to accept as `release`.
  factory TrustAnchors.ofPolicy(Map<String, String> fields) {
    final keys = <String, String>{
      for (final row in fields['keys']!.split(','))
        if (row.contains(':')) row.split(':')[0]: row.split(':')[1],
    };
    require(
      keys['release'] != null,
      'KEYS_NOT_CONFIGURED',
      'The host policy names no release publisher key.',
    );
    return TrustAnchors(
      root: fields['root_key']!,
      publisher: keys['release']!,
      patch: fields['fptc_key']!,
    );
  }

  final String root, publisher, patch;

  String of(KeyRole role) => switch (role) {
    KeyRole.root => root,
    KeyRole.publisher => publisher,
    KeyRole.patch => patch,
  };

  /// The key store directory of this project: the trust root names it, so
  /// flavors and application ids that share keys share it too.
  String get id =>
      sha256.convert(base64Decode(root)).toString().substring(0, 16);

  /// A copy whose publisher key is [publisher], after a rotation.
  TrustAnchors withPublisher(String publisher) =>
      TrustAnchors(root: root, publisher: publisher, patch: patch);
}

bool _isPublicKey(String value) {
  try {
    final raw = base64Decode(value);
    return raw.length == 32 && base64Encode(raw) == value;
  } on FormatException {
    return false;
  }
}

/// A project's private keys: a seed per role. Public keys are derived, never
/// stored. One file moves a project's keys between machines.
final class KeyBundle {
  KeyBundle(Map<KeyRole, Uint8List> seeds) : seeds = Map.unmodifiable(seeds) {
    require(
      seeds.isNotEmpty && seeds.values.every((seed) => seed.length == 32),
      'KEYS_BUNDLE_INVALID',
      'A key bundle holds 32-byte Ed25519 seeds.',
    );
  }

  static const format = 'flutter_patcher.keys.v1';

  final Map<KeyRole, Uint8List> seeds;

  static KeyBundle generate() => KeyBundle({
    for (final role in KeyRole.values) role: ed25519GenerateSeed(),
  });

  /// A bundle as [encode] writes it, or that JSON in base64 (as CI secrets
  /// usually hold it).
  static KeyBundle decode(String text) {
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
      final roles = {for (final role in KeyRole.values) role.name: role};
      return KeyBundle({
        for (final entry in keys.entries)
          roles[entry.key] ?? (throw const FormatException()): _seed(
            entry.value,
          ),
      });
    } on Failure {
      rethrow;
    } catch (_) {
      throw Failure(
        'KEYS_BUNDLE_INVALID',
        'Not a flutter_patcher key bundle ($format).',
      );
    }
  }

  static Uint8List _seed(Object? value) {
    if (value is! String) throw const FormatException();
    final raw = base64Decode(value);
    if (raw.length != 32 || base64Encode(raw) != value) {
      throw const FormatException();
    }
    return raw;
  }

  /// The pre-1.0 layout `keys init` wrote: `<dir>/<role>/private-key.base64`.
  static Future<KeyBundle> readDirectory(String directory) async {
    final seeds = <KeyRole, Uint8List>{};
    for (final role in KeyRole.values) {
      final file = File(p.join(directory, role.name, 'private-key.base64'));
      await rejectLinks(file.path);
      if (!await file.exists()) continue;
      try {
        seeds[role] = _seed((await file.readAsString()).trim());
      } catch (_) {
        throw Failure('KEYS_BUNDLE_INVALID', 'Invalid key file: ${file.path}');
      }
    }
    require(
      seeds.isNotEmpty,
      'KEYS_BUNDLE_INVALID',
      'No private keys in $directory.',
    );
    return KeyBundle(seeds);
  }

  /// Canonical JSON: roles in a fixed order, so equal bundles encode equally.
  String encode() => jsonEncode({
    'format': format,
    'keys': {
      for (final role in KeyRole.values)
        if (seeds[role] != null) role.name: base64Encode(seeds[role]!),
    },
  });

  KeyBundle without(KeyRole role) => KeyBundle({...seeds}..remove(role));

  String publicKey(KeyRole role) =>
      base64Encode(ed25519PublicKey(seeds[role]!));

  /// The anchors of a complete bundle.
  TrustAnchors get anchors {
    require(
      seeds.length == KeyRole.values.length,
      'KEYS_BUNDLE_INVALID',
      'This key bundle lacks ${KeyRole.values.where((r) => seeds[r] == null).map((r) => r.name).join(', ')}.',
    );
    return TrustAnchors(
      root: publicKey(KeyRole.root),
      publisher: publicKey(KeyRole.publisher),
      patch: publicKey(KeyRole.patch),
    );
  }

  /// Whether every role this bundle holds has [anchors]' public key.
  bool matches(TrustAnchors anchors) =>
      seeds.keys.every((role) => publicKey(role) == anchors.of(role));
}

/// Where a user's key bundles live: `~/.flutter_patcher/keys`.
String keyStoreRoot({Map<String, String>? environment}) {
  final env = environment ?? Platform.environment;
  final home = env['HOME'] ?? env['USERPROFILE'];
  require(home != null, 'CONFIG_INVALID', 'HOME (or USERPROFILE) is not set.');
  return p.join(home!, '.flutter_patcher', 'keys');
}

String _bundlePath(String root, TrustAnchors anchors) =>
    p.join(root, anchors.id, 'keys.json');

/// The stored bundle of [anchors]' project, or null. A stored bundle whose
/// keys are not [anchors]' is an error, never silently skipped.
Future<KeyBundle?> loadKeyStore(TrustAnchors anchors, {String? root}) async {
  final path = _bundlePath(root ?? keyStoreRoot(), anchors);
  await rejectLinks(path);
  if (!await File(path).exists()) return null;
  final bundle = KeyBundle.decode(await File(path).readAsString());
  require(
    bundle.matches(anchors),
    'KEYS_MISMATCH',
    'The key store holds other keys for this project: $path',
  );
  return bundle;
}

/// Stores [bundle], whose keys must be [anchors]', under the project's root
/// key and returns the file. A bundle without the root key (as CI exports
/// it) is stored too. A stored bundle is only ever completed (a role added)
/// or, with [replace], given a new publisher key; any other difference is
/// KEYS_MISMATCH.
Future<String> saveKeyStore(
  KeyBundle bundle,
  TrustAnchors anchors, {
  String? root,
  bool replace = false,
}) async {
  require(
    bundle.matches(anchors),
    'KEYS_MISMATCH',
    'These keys are not the ones this project\'s hosts trust.',
  );
  final directory = p.join(root ?? keyStoreRoot(), anchors.id);
  final path = p.join(directory, 'keys.json');
  await rejectLinks(path);
  if (await File(path).exists()) {
    final stored = KeyBundle.decode(await File(path).readAsString());
    final common = stored.seeds.keys.where(bundle.seeds.containsKey);
    final differs = common
        .where((role) => stored.publicKey(role) != bundle.publicKey(role))
        .toSet();
    require(
      differs.isEmpty ||
          (replace && differs.every((r) => r == KeyRole.publisher)),
      'KEYS_MISMATCH',
      'The key store already holds other ${differs.map((r) => r.name).join(', ')} keys for this project: $path',
    );
    final merged = KeyBundle({...stored.seeds, ...bundle.seeds});
    if (merged.encode() == stored.encode()) return path;
    await _writePrivate(path, merged.encode());
    return path;
  }
  await Directory(p.dirname(directory)).create(recursive: true);
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
