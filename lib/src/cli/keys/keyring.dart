import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../core.dart';
import '../crypto/ed25519.dart';
import '../project.dart';
import 'bundle.dart';
import 'signer.dart';

/// Where a project's private keys come from. The only way the CLI reaches
/// them: patch and build never do.
///
/// A role's signer is the first of: the [keyFile] bundle, the
/// `FLUTTER_PATCHER_KEYS` bundle, the [command], the user's key store. A
/// source may hold only some roles (CI usually lacks root); a source holding
/// a role with a key other than the anchor's is an error, never skipped.
final class Keyring {
  Keyring(
    this.anchors, {
    this.keyFile,
    this.command,
    this.keyStore,
    Map<String, String>? environment,
  }) : _environment = environment ?? Platform.environment;

  final TrustAnchors anchors;
  final String? keyFile, command;

  /// The key store root; default ~/.flutter_patcher/keys.
  final String? keyStore;
  final Map<String, String> _environment;

  static const environmentVariable = 'FLUTTER_PATCHER_KEYS';

  /// The keyring of a project: its trust keys and signing command from
  /// flutter_patcher.yaml.
  static Keyring forProject(ProjectConfig config, {String? keyFile}) => Keyring(
    config.requireAnchors(),
    keyFile: keyFile,
    command: config.signingCommand,
  );

  /// The signer of [role], checked against [anchors]: every signature it
  /// returns has been verified.
  Future<Signer> signer(KeyRole role) async {
    final found = await _find(role);
    require(
      found != null,
      'KEYS_NOT_FOUND',
      'No ${role.name} private key in ${_sources.join(', ')}. Run '
          '`flutter_patcher keys import`, set $environmentVariable or '
          'configure signing.command.',
    );
    require(
      found!.publicKey == anchors.of(role),
      'KEYS_MISMATCH',
      'The ${role.name} key from ${found.source} is not the one this '
          'project\'s hosts trust.',
    );
    return _Verified(found);
  }

  /// Which source would sign for each role, without signing: for
  /// `keys status` and doctor. A source that fails to load reports its error.
  Future<Map<KeyRole, String>> describe() async => {
    for (final role in KeyRole.values)
      role: await _find(role).then(
        (s) => s == null
            ? 'none'
            : s.publicKey == anchors.of(role)
            ? s.source
            : '${s.source} (other key)',
        onError: (Object e) => e is Failure ? e.code : '$e',
      ),
  };

  List<String> get _sources => [
    if (keyFile != null) '--key-file',
    environmentVariable,
    if (command != null) 'signing.command',
    'the key store',
  ];

  Future<Signer?> _find(KeyRole role) async {
    if (keyFile != null) {
      await rejectLinks(keyFile!);
      require(
        await File(keyFile!).exists(),
        'KEYS_NOT_FOUND',
        'No key file at $keyFile.',
      );
      final signer = _fromBundle(
        KeyBundle.decode(await File(keyFile!).readAsString()),
        role,
        '--key-file',
      );
      if (signer != null) return signer;
    }
    final variable = _environment[environmentVariable];
    if (variable != null && variable.trim().isNotEmpty) {
      final signer = _fromBundle(
        KeyBundle.decode(variable),
        role,
        environmentVariable,
      );
      if (signer != null) return signer;
    }
    if (command != null) {
      return CommandSigner(
        role,
        command!,
        anchors.of(role),
        environment: _environment,
      );
    }
    final stored = await loadKeyStore(
      anchors,
      root: keyStore ?? keyStoreRoot(environment: _environment),
    );
    return stored == null ? null : _fromBundle(stored, role, 'key store');
  }

  Signer? _fromBundle(KeyBundle bundle, KeyRole role, String source) {
    final seed = bundle.seeds[role];
    return seed == null ? null : SeedSigner(role, seed, source);
  }
}

/// Verifies every signature against the anchor before returning it, so a
/// misbehaving command or a corrupted seed fails closed.
final class _Verified implements Signer {
  _Verified(this._inner);
  final Signer _inner;

  @override
  KeyRole get role => _inner.role;
  @override
  String get publicKey => _inner.publicKey;
  @override
  String get source => _inner.source;

  @override
  Future<Uint8List> sign(List<int> message) async {
    final signature = await _inner.sign(message);
    require(
      ed25519Verify(base64Decode(publicKey), signature, message),
      _inner is CommandSigner ? 'SIGNER_COMMAND_FAILED' : 'KEYS_MISMATCH',
      'The ${role.name} signature from $source does not verify.',
    );
    return signature;
  }
}
