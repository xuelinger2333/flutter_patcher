import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../core.dart';
import '../crypto/ed25519.dart';
import 'bundle.dart';

/// Signs bytes as one role. [Keyring] checks the public key and verifies
/// every signature before anything uses it.
abstract interface class Signer {
  KeyRole get role;

  /// The base64 Ed25519 public key it signs for.
  String get publicKey;

  /// Where its key came from, for diagnostics: `--key-file`,
  /// `FLUTTER_PATCHER_KEYS`, `signing.command` or `key store`.
  String get source;

  Future<Uint8List> sign(List<int> message);
}

/// A seed held in memory for this run only.
final class SeedSigner implements Signer {
  SeedSigner(this.role, this._seed, this.source)
    : publicKey = base64Encode(ed25519PublicKey(_seed));

  @override
  final KeyRole role;
  @override
  final String publicKey, source;
  final Uint8List _seed;

  @override
  Future<Uint8List> sign(List<int> message) async =>
      ed25519Sign(_seed, message);
}

/// An external program signs: the message on stdin, a base64 Ed25519
/// signature on stdout. The private key never enters this process, so it can
/// stay in a KMS, Vault, an HSM or a password manager.
final class CommandSigner implements Signer {
  CommandSigner(
    this.role,
    this.command,
    this.publicKey, {
    Map<String, String>? environment,
    this.timeout = const Duration(seconds: 60),
  }) : _environment = environment ?? Platform.environment;

  @override
  final KeyRole role;
  @override
  final String publicKey;
  @override
  String get source => 'signing.command';
  final String command;
  final Duration timeout;
  final Map<String, String> _environment;

  @override
  Future<Uint8List> sign(List<int> message) async {
    // cmd.exe does not parse the quoting Process.start applies to arguments,
    // so on Windows the command runs from a batch file, exactly as written.
    final script = Platform.isWindows
        ? await Directory.systemTemp.createTemp('flutter_patcher-sign-')
        : null;
    try {
      final Process process;
      try {
        final environment = {
          // The command gets no key bundle, only what it needs to sign.
          for (final e in _environment.entries)
            if (e.key != 'FLUTTER_PATCHER_KEYS') e.key: e.value,
          'FLUTTER_PATCHER_SIGN_ROLE': role.name,
          'FLUTTER_PATCHER_SIGN_PUBLIC_KEY': publicKey,
        };
        if (script == null) {
          process = await Process.start(
            '/bin/sh',
            ['-c', command],
            includeParentEnvironment: false,
            environment: environment,
          );
        } else {
          final batch = File('${script.path}${Platform.pathSeparator}sign.cmd')
            ..writeAsStringSync(
              '@echo off\r\n$command\r\nexit /b %ERRORLEVEL%\r\n',
            );
          process = await Process.start(
            'cmd.exe',
            ['/d', '/c', batch.path],
            includeParentEnvironment: false,
            environment: environment,
          );
        }
      } on ProcessException catch (error) {
        throw Failure(
          'SIGNER_COMMAND_FAILED',
          'Cannot start: ${error.message}',
        );
      }
      return await _collect(process, message);
    } finally {
      try {
        await script?.delete(recursive: true);
      } on FileSystemException {
        // A command killed on timeout may still hold its batch file.
      }
    }
  }

  Future<Uint8List> _collect(Process process, List<int> message) async {
    final output = collectOutput(process.stdout);
    final errors = collectOutput(process.stderr);
    try {
      process.stdin.add(message);
      await process.stdin.close();
    } on Object {
      // A command that exits without reading reports through its exit code.
    }
    final int code;
    try {
      code = await process.exitCode.timeout(timeout);
    } on TimeoutException {
      process.kill();
      throw Failure(
        'SIGNER_COMMAND_FAILED',
        'No signature within ${timeout.inSeconds} s.',
      );
    }
    final detail = await errors;
    require(
      code == 0,
      'SIGNER_COMMAND_FAILED',
      'Exit code $code: ${detail.length > 2048 ? detail.substring(0, 2048) : detail}',
    );
    try {
      final signature = base64Decode((await output).trim());
      if (signature.length == 64) return signature;
    } on FormatException {
      // Reported below.
    }
    throw Failure(
      'SIGNER_COMMAND_FAILED',
      'The command must print a base64 64-byte Ed25519 signature.',
    );
  }
}
