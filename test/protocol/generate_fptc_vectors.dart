// Writes test/protocol/fptc-v1.json, the FPTC v1 vectors shared by the CLI,
// the Dart plugin, Android and iOS. Files are assembled here byte by byte
// from the format in plan/1.1-direct-patching.md §4.2, not by the CLI's
// sealing code, so the CLI is tested against the format rather than itself.
//
//   dart run test/protocol/generate_fptc_vectors.dart
//
// The seeds are the public RFC 8032 test seeds. Never sign real patches
// with them.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_patcher/src/cli/crypto/ed25519.dart';

final _seedA = _hex(
  '9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60',
);
final _seedB = _hex(
  '4ccd089b28ff96da9db6c346ec114e0f5b8a319f35aba624da8cf6ed4fb8a6fb',
);
final _fingerprint = 'ab' * 32;
final _other = 'cd' * 32;

Uint8List _hex(String text) => Uint8List.fromList([
  for (var i = 0; i < text.length; i += 2)
    int.parse(text.substring(i, i + 2), radix: 16),
]);

/// One FPTC v1 file. [seed] null leaves the signature zero.
Uint8List file({
  required List<int> payload,
  required int seq,
  String? fingerprint,
  List<int>? seed,
  int magic = 0x46505443,
  int version = 1,
  int? length,
  List<int>? digest,
}) {
  final header = ByteData(82)
    ..setUint32(0, magic)
    ..setUint16(4, version);
  final bytes = header.buffer.asUint8List();
  bytes.setRange(6, 38, _hex(fingerprint ?? _fingerprint));
  header
    ..setUint32(38, seq)
    ..setUint64(42, length ?? payload.length);
  bytes.setRange(50, 82, digest ?? sha256.convert(payload).bytes);
  final signature = seed == null
      ? Uint8List(64)
      : ed25519Sign(seed, [...bytes, ...payload]);
  return Uint8List.fromList([...bytes, ...signature, ...payload]);
}

Map<String, Object?> row(
  String name,
  Uint8List bytes, {
  required List<int>? hostSeed,
  int? seq,
  String? action,
  String? reason,
}) => {
  'name': name,
  'fingerprint': _fingerprint,
  'host_key': hostSeed == null
      ? null
      : base64Encode(ed25519PublicKey(hostSeed)),
  'file': base64Encode(bytes),
  'valid': seq != null,
  'seq': ?seq,
  if (seq != null) 'action': action,
  'reason': ?reason,
};

void main() {
  final payload = utf8.encode('FPTC v1 vector payload');
  final valid = file(payload: payload, seq: 1793520000, seed: _seedA);
  Uint8List flip(Uint8List bytes, int offset) =>
      Uint8List.fromList(bytes)..[offset] ^= 1;

  final files = [
    row(
      'signed patch, signed host',
      valid,
      hostSeed: _seedA,
      seq: 1793520000,
      action: 'publish',
    ),
    row(
      'unsigned patch, unsigned host',
      file(payload: payload, seq: 1793520000),
      hostSeed: null,
      seq: 1793520000,
      action: 'publish',
    ),
    row(
      'signed patch, unsigned host',
      valid,
      hostSeed: null,
      seq: 1793520000,
      action: 'publish',
    ),
    row(
      'signed withdrawal, signed host',
      file(payload: const [], seq: 1793520001, seed: _seedA),
      hostSeed: _seedA,
      seq: 1793520001,
      action: 'withdraw',
    ),
    row(
      'unsigned withdrawal, unsigned host',
      file(payload: const [], seq: 1793520001),
      hostSeed: null,
      seq: 1793520001,
      action: 'withdraw',
    ),
    row(
      'largest sequence',
      file(payload: payload, seq: 0xffffffff, seed: _seedA),
      hostSeed: _seedA,
      seq: 0xffffffff,
      action: 'publish',
    ),
    row(
      'unsigned patch, signed host',
      file(payload: payload, seq: 1),
      hostSeed: _seedA,
      reason: 'signature',
    ),
    row(
      'another key, signed host',
      file(payload: payload, seq: 1, seed: _seedB),
      hostSeed: _seedA,
      reason: 'signature',
    ),
    row(
      'signature byte flipped',
      flip(valid, 100),
      hostSeed: _seedA,
      reason: 'signature',
    ),
    row(
      'payload changed, digest updated, signed host',
      () {
        final changed = utf8.encode('FPTC v1 vector payloae');
        final bytes = file(payload: changed, seq: 1793520000);
        bytes.setRange(82, 146, valid.sublist(82, 146));
        return bytes;
      }(),
      hostSeed: _seedA,
      reason: 'signature',
    ),
    row(
      'payload changed, unsigned host',
      flip(valid, 146),
      hostSeed: null,
      reason: 'digest',
    ),
    row(
      'digest byte flipped, unsigned host',
      flip(valid, 50),
      hostSeed: null,
      reason: 'digest',
    ),
    row(
      'magic',
      file(payload: payload, seq: 1, magic: 0x46505444),
      hostSeed: null,
      reason: 'magic',
    ),
    row(
      'version 2',
      file(payload: payload, seq: 1, version: 2),
      hostSeed: null,
      reason: 'version',
    ),
    row(
      'another host',
      file(payload: payload, seq: 1, fingerprint: _other),
      hostSeed: null,
      reason: 'fingerprint',
    ),
    row(
      'sequence 0',
      file(payload: payload, seq: 0),
      hostSeed: null,
      reason: 'sequence',
    ),
    row(
      'length larger than the file',
      file(payload: payload, seq: 1, length: payload.length + 1),
      hostSeed: null,
      reason: 'length',
    ),
    row(
      'bytes after the payload',
      Uint8List.fromList([...file(payload: payload, seq: 1), 0]),
      hostSeed: null,
      reason: 'length',
    ),
    row(
      'header cut short',
      file(payload: payload, seq: 1).sublist(0, 145),
      hostSeed: null,
      reason: 'length',
    ),
  ];

  // The default flavor and channel are left out; otherwise both are named.
  Map<String, Object> name(
    String versionCode,
    String flavor,
    String channel,
    String abi,
    String fileName,
  ) => {
    'scope': {
      'version_code': versionCode,
      'flavor': flavor,
      'channel': channel,
      'abi': abi,
    },
    'file_name': fileName,
  };
  final names = [
    name('7', 'default', 'production', 'arm64-v8a', '7-arm64-v8a.fptc'),
    name('7', 'default', 'production', 'ios-arm64', '7-ios-arm64.fptc'),
    name('3', 'default', 'beta', 'arm64-v8a', '3-default-beta-arm64-v8a.fptc'),
    name(
      '3',
      'paid',
      'production',
      'arm64-v8a',
      '3-paid-production-arm64-v8a.fptc',
    ),
    name(
      '2100000000',
      'paid_Pro1',
      'beta',
      'ios-arm64',
      '2100000000-paid_Pro1-beta-ios-arm64.fptc',
    ),
  ];

  File('test/protocol/fptc-v1.json').writeAsStringSync(
    '${const JsonEncoder.withIndent('  ').convert({'files': files, 'file_names': names})}\n',
  );
}
