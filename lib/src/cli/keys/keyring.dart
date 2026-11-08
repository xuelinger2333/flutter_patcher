import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../core.dart';
import '../crypto/ed25519.dart';
import 'bundle.dart';
import 'signer.dart';

/// Where the private half of [patchKey] comes from. The only way the CLI
/// reaches it: patch and build never do.
///
/// The signer is the first of: the [keyFile] bundle, the
/// `FLUTTER_PATCHER_KEYS` bundle, the [command], the user's key store. A
/// source holding another key is an error, never skipped.
final class Keyring {
  Keyring(
    this.patchKey, {
    this.keyFile,
    this.command,
    this.keyStore,
    Map<String, String>? environment,
  }) : _environment = environment ?? Platform.environment;

  /// The base64 public key hosts trust.
  final String patchKey;
  final String? keyFile, command;

  /// The key store root; default ~/.flutter_patcher/keys.
  final String? keyStore;
  final Map<String, String> _environment;

  static const environmentVariable = 'FLUTTER_PATCHER_KEYS';

  /// The signer of [patchKey]: every signature it returns has been verified.
  Future<Signer> signer() async {
    final found = await _find();
    require(
      found != null,
      'KEYS_NOT_FOUND',
      'No private key for patch key $patchKey in ${_sources.join(', ')}. '
          'Run `flutter_patcher keys import`, set $environmentVariable or '
          'configure signing.command.',
    );
    require(
      found!.publicKey == patchKey,
      'KEYS_MISMATCH',
      'The key from ${found.source} is not $patchKey, the one these hosts '
          'trust.',
    );
    return _Verified(found);
  }

  /// Which source would sign, without signing: for `keys status` and doctor.
  /// A source that fails to load reports its error.
  Future<String> describe() => _find().then(
    (s) => s == null
        ? 'none'
        : s.publicKey == patchKey
        ? s.source
        : '${s.source} (other key)',
    onError: (Object e) => e is Failure ? e.code : '$e',
  );

  List<String> get _sources => [
    if (keyFile != null) '--key-file',
    environmentVariable,
    if (command != null) 'signing.command',
    'the key store',
  ];

  Future<Signer?> _find() async {
    if (keyFile != null) {
      await rejectLinks(keyFile!);
      require(
        await File(keyFile!).exists(),
        'KEYS_NOT_FOUND',
        'No key file at $keyFile.',
      );
      return SeedSigner(
        KeyBundle.decode(await File(keyFile!).readAsString()).seed,
        '--key-file',
      );
    }
    final variable = _environment[environmentVariable];
    if (variable != null && variable.trim().isNotEmpty) {
      return SeedSigner(KeyBundle.decode(variable).seed, environmentVariable);
    }
    if (command != null) {
      return CommandSigner(command!, patchKey, environment: _environment);
    }
    final stored = await loadKeyStore(
      patchKey,
      root: keyStore ?? keyStoreRoot(environment: _environment),
    );
    return stored == null ? null : SeedSigner(stored.seed, 'key store');
  }
}

/// Verifies every signature against [Keyring.patchKey] before returning it,
/// so a misbehaving command or a corrupted seed fails closed.
final class _Verified implements Signer {
  _Verified(this._inner);
  final Signer _inner;

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
      'The signature from $source does not verify.',
    );
    return signature;
  }
}
