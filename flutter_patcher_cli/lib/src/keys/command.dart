import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'package:args/args.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import '../core.dart';

ArgParser keysOptions() => ArgParser()
  ..addFlag('help', abbr: 'h', negatable: false)
  ..addFlag('json', negatable: false, help: 'Output contains metadata only.')
  ..addOption('out',
      help: 'New key directory; default ~/.flutter_patcher/keys.');

/// Binary output is kept in memory. Never include key material in diagnostics.
Future<List<int>> _openssl(List<String> arguments, [List<int>? input]) async {
  Process process;
  try {
    process = await Process.start('openssl', arguments);
  } on ProcessException {
    throw Failure('KEYS_CRYPTO_UNAVAILABLE',
        'OpenSSL with Ed25519 support is required on PATH.');
  }
  final output = process.stdout.fold<List<int>>([], (a, b) => a..addAll(b));
  final errors = process.stderr.drain<void>();
  if (input != null) process.stdin.add(input);
  try {
    final closed = process.stdin.close();
    final code = await process.exitCode.timeout(const Duration(seconds: 30));
    await closed;
    await errors;
    final bytes = await output;
    require(code == 0, 'KEYS_CRYPTO_FAILED',
        'OpenSSL could not generate or derive the Ed25519 key.');
    return bytes;
  } on TimeoutException {
    process.kill(ProcessSignal.sigkill);
    await process.exitCode;
    await errors;
    await output;
    throw Failure('KEYS_CRYPTO_FAILED', 'OpenSSL timed out.');
  }
}

bool _prefix(List<int> bytes, List<int> prefix) =>
    bytes.length >= prefix.length &&
    List.generate(prefix.length, (i) => bytes[i] == prefix[i]).every((v) => v);

Future<int> keysCommand(ArgResults args) async {
  require(args.rest.length == 1 && args.rest.single == 'init', 'USAGE_ERROR',
      'Use keys init [--out <new-directory>].');
  require(Abi.current() == Abi.linuxX64, 'HOST_UNSUPPORTED',
      'M1 keys init supports Linux x64, including x64 WSL2.');
  final home = Platform.environment['HOME'];
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
  // RFC 8410 PKCS#8: version 0, id-Ed25519, absent parameters, nested raw32 seed.
  final secret =
      await _openssl(['genpkey', '-algorithm', 'ED25519', '-outform', 'DER']);
  require(
      secret.length == 48 &&
          _prefix(secret, [
            0x30,
            0x2e,
            0x02,
            0x01,
            0,
            0x30,
            0x05,
            0x06,
            0x03,
            0x2b,
            0x65,
            0x70,
            0x04,
            0x22,
            0x04,
            0x20
          ]),
      'KEYS_CRYPTO_FAILED',
      'Unexpected Ed25519 private-key encoding.');
  final public = await _openssl(
      ['pkey', '-inform', 'DER', '-pubout', '-outform', 'DER'], secret);
  require(
      public.length == 44 &&
          _prefix(public, [
            0x30,
            0x2a,
            0x30,
            0x05,
            0x06,
            0x03,
            0x2b,
            0x65,
            0x70,
            0x03,
            0x21,
            0
          ]),
      'KEYS_CRYPTO_FAILED',
      'Unexpected Ed25519 public-key encoding.');
  await Directory(p.dirname(out)).create(recursive: true);
  await rejectLinks(out);
  // mkdir is exclusive, unlike Directory.create: competing initializers cannot
  // both succeed. Mode 700 is applied at creation, before any secret is written.
  final claim = await Process.run('mkdir', ['-m', '700', '--', out]);
  require(claim.exitCode == 0, 'KEYS_OUTPUT_UNAVAILABLE',
      'Cannot exclusively create key directory (already exists or is not writable): $out');
  final privateFile = File(p.join(out, 'private-key.base64'));
  final publicFile = File(p.join(out, 'public-key.base64'));
  final ignoreFile = File(p.join(out, '.gitignore'));
  try {
    await privateFile.create();
    final mode = await Process.run('chmod', ['600', '--', privateFile.path]);
    require(mode.exitCode == 0, 'KEYS_PERMISSIONS_FAILED',
        'Cannot protect private-key permissions.');
    await privateFile.writeAsString('${base64Encode(secret.sublist(16))}\n',
        flush: true);
    await publicFile.writeAsString('${base64Encode(public.sublist(12))}\n',
        flush: true);
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
      'public_key_sha256': sha256.convert(public.sublist(12)).toString()
    }));
    return 0;
  } catch (_) {
    // Only our known files; never recursively delete an output directory.
    for (final file in [privateFile, publicFile, ignoreFile]) {
      if (await file.exists()) await file.delete();
    }
    try {
      await Directory(out).delete();
    } on FileSystemException {/* Retain foreign files. */}
    rethrow;
  }
}
