import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'crc32.dart';

void bootRequire(bool value, String reason) {
  if (!value) throw FormatException(reason);
}

/// Strict, read-only STORED ZIP reader. Central and local records must agree;
/// no extraction, ambiguous paths, data descriptors, zip64 or trailing data.
Map<String, Uint8List> readPatchArchive(Uint8List bytes,
    {Map<String, int>? profile}) {
  final view = ByteData.sublistView(bytes);
  void range(int p, int n) =>
      bootRequire(p >= 0 && n >= 0 && p + n <= bytes.length, 'ZIP bounds');
  int u16(int p) {
    range(p, 2);
    return view.getUint16(p, Endian.little);
  }

  int u32(int p) {
    range(p, 4);
    return view.getUint32(p, Endian.little);
  }

  String name(int p, int n) {
    range(p, n);
    final s = utf8.decode(bytes.sublist(p, p + n));
    bootRequire(
        s.isNotEmpty &&
            !s.contains('\\') &&
            !s.contains(':') &&
            !s.contains('\u0000') &&
            s.split('/').every((v) => v.isNotEmpty && v != '.' && v != '..'),
        'ZIP path');
    return s;
  }

  final end = bytes.length - 22;
  bootRequire(
      u32(end) == 0x06054b50 &&
          u16(end + 4) == 0 &&
          u16(end + 6) == 0 &&
          u16(end + 20) == 0,
      'ZIP end record');
  final count = u16(end + 10), central = u32(end + 16), size = u32(end + 12);
  bootRequire(
      count > 0 &&
          count <= 4096 &&
          u16(end + 8) == count &&
          central + size == end,
      'ZIP directory');
  final result = <String, Uint8List>{};
  var cp = central, lp = 0;
  for (var i = 0; i < count; i++) {
    bootRequire(u32(cp) == 0x02014b50 && u32(lp) == 0x04034b50, 'ZIP record');
    final flags = u16(cp + 8),
        n = u16(cp + 28),
        extra = u16(cp + 30),
        comment = u16(cp + 32),
        length = u32(cp + 24);
    bootRequire(
        (flags & ~0x800) == 0 &&
            u16(cp + 10) == 0 &&
            length == u32(cp + 20) &&
            length <= 64 * 1024 * 1024 &&
            extra == 0 &&
            comment == 0 &&
            u16(cp + 34) == 0 &&
            u32(cp + 42) == lp,
        'ZIP unsupported entry');
    final file = name(cp + 46, n);
    final attributes = u32(cp + 38), mode = (attributes >> 16) & 0xf000;
    bootRequire(mode == 0 || mode == 0x8000, 'ZIP non-regular entry');
    bootRequire((attributes & 0x10) == 0 && !result.containsKey(file),
        'ZIP duplicate/directory');
    bootRequire(
        u16(lp + 6) == flags &&
            u16(lp + 8) == 0 &&
            u32(lp + 14) == u32(cp + 16) &&
            u32(lp + 18) == length &&
            u32(lp + 22) == length &&
            u16(lp + 26) == n &&
            u16(lp + 28) == 0 &&
            name(lp + 30, n) == file,
        'ZIP local/central mismatch');
    final start = lp + 30 + n;
    range(start, length);
    bootRequire(start + length <= central, 'ZIP overlapping entry');
    final content = Uint8List.sublistView(bytes, start, start + length);
    final crcWatch = profile == null ? null : (Stopwatch()..start());
    final crc = patchCrc32(content);
    if (crcWatch != null) {
      profile!['zip_crc_us'] =
          (profile['zip_crc_us'] ?? 0) + crcWatch.elapsedMicroseconds;
    }
    bootRequire(crc == u32(cp + 16), 'ZIP CRC mismatch');
    result[file] = content;
    lp = start + length;
    cp += 46 + n;
  }
  bootRequire(lp == central && cp == end, 'ZIP unlisted bytes');
  return result;
}

class VerifiedPatch {
  VerifiedPatch(this.module, this.assets, this.fonts, this.seq, this.tier);
  final Uint8List module;
  final Map<String, Uint8List> assets;
  final Map<String, List<Uint8List>> fonts;
  final int seq;
  final String tier;
}

VerifiedPatch verifyPatchBytes(
    Uint8List bytes, String fingerprint, String verifiedSha256,
    {Map<String, int>? profile}) {
  final watch = profile == null ? null : (Stopwatch()..start());
  var checkpoint = 0;
  void mark(String name) {
    if (watch == null) return;
    final now = watch.elapsedMicroseconds;
    profile![name] = now - checkpoint;
    checkpoint = now;
  }

  bootRequire(bytes.length >= 146 && bytes.length <= 320 * 1024 * 1024,
      'Envelope size');
  final data = ByteData.sublistView(bytes);
  bootRequire(data.getUint64(42) == bytes.length - 146, 'Envelope length');
  bootRequire(data.getUint32(0) == 0x46505443, 'Envelope magic');
  bootRequire(data.getUint16(4) == 1, 'Envelope version');
  final fp = bytes
      .sublist(6, 38)
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join();
  bootRequire(fp == fingerprint, 'Envelope fingerprint');
  final payload = Uint8List.sublistView(bytes, 146);
  mark('envelope_fields_us');
  bootRequire(
      sha256.convert(payload).bytes.toString() ==
          bytes.sublist(50, 82).toString(),
      'Envelope hash');
  mark('payload_sha256_us');
  // Native bootPayload verified Ed25519 with the embedded public key. Bind its
  // attestation to these exact bytes so a path replacement cannot bypass it.
  bootRequire(sha256.convert(bytes).toString() == verifiedSha256,
      'Verified file changed');
  mark('file_sha256_us');
  final entries = readPatchArchive(payload, profile: profile);
  mark('zip_total_us');
  bootRequire(
      entries.containsKey('module.bc') &&
          entries.containsKey('patch_manifest.json'),
      'Required entries');
  bootRequire(entries['patch_manifest.json']!.length <= 4 * 1024 * 1024,
      'Manifest size');
  final decoded = jsonDecode(utf8.decode(entries['patch_manifest.json']!));
  bootRequire(decoded is Map, 'Manifest object');
  final manifest = decoded as Map;
  final seq = data.getUint32(38), tier = manifest['tier'];
  bootRequire(
      seq > 0 &&
          manifest['format_version'] is int &&
          manifest['patch_seq'] is int &&
          manifest['format_version'] == 1 &&
          manifest['patch_seq'] == seq &&
          manifest['fingerprint'] == fingerprint &&
          (tier == 'lean' || tier == 'whole'),
      'Manifest identity');
  final listed = {'patch_manifest.json'};
  Uint8List entry(Object? value, String prefix) {
    bootRequire(value is Map && value['path'] is String, 'Manifest entry');
    final row = value as Map;
    final path = row['path'] as String, content = entries[path];
    bootRequire(path.startsWith(prefix) && listed.add(path) && content != null,
        'Unlisted/duplicate entry');
    final hashWatch = profile == null ? null : (Stopwatch()..start());
    bootRequire(
        row['length'] is int &&
            row['length'] == content!.length &&
            row['sha256'] == sha256.convert(content).toString(),
        'Entry digest');
    if (hashWatch != null) {
      profile!['entry_sha256_us'] =
          (profile['entry_sha256_us'] ?? 0) + hashWatch.elapsedMicroseconds;
    }
    return content!;
  }

  final moduleRow = manifest['module'];
  bootRequire(
      moduleRow is Map && moduleRow['path'] == 'module.bc', 'Module path');
  final module = entry(manifest['module'], 'module.bc');
  bootRequire(
      module.length >= 120 &&
          ByteData.sublistView(module).getUint32(0, Endian.little) ==
              0x44424333,
      'Bytecode magic');
  bootRequire(manifest['assets'] is List && manifest['fonts'] is List,
      'Resource lists');
  final assets = <String, Uint8List>{}, fonts = <String, List<Uint8List>>{};
  for (final value in manifest['assets'] as List) {
    final Object? row = value;
    bootRequire(
        row is Map &&
            row['key'] is String &&
            row['path'] == 'assets/${row['key']}' &&
            !assets.containsKey(row['key']),
        'Asset key');
    final record = row as Map;
    assets[record['key'] as String] = entry(record, 'assets/');
  }
  for (final value in manifest['fonts'] as List) {
    final Object? row = value;
    bootRequire(
        row is Map &&
            row['family'] is String &&
            (row['family'] as String).isNotEmpty,
        'Font family');
    final record = row as Map;
    fonts
        .putIfAbsent(record['family'] as String, () => [])
        .add(entry(record, 'fonts/'));
  }
  bootRequire(listed.length == entries.length, 'Unlisted ZIP entries');
  mark('manifest_and_entries_us');
  if (profile != null) {
    profile['file_bytes'] = bytes.length;
    profile['module_bytes'] = module.length;
    profile['entry_count'] = entries.length;
  }
  return VerifiedPatch(module, assets, fonts, seq, tier as String);
}
