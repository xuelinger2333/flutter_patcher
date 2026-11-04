import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart' hide ZLibEncoder;
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../core.dart';
import 'resources.dart';
export '../crypto/signing.dart' show hexBytes;

/// Patch archive manifest version; must match the plugin's reader.
const patchFormatVersion = 2;

/// The archive entry of each kind of code: a bytecode module the plugin
/// loads, or an SO host's rebuilt libapp.so that native code loads.
const codePaths = {'bytecode': 'module.bc', 'libapp': 'libapp.so'};

/// A ZIP of [entries] as the device readers accept it: plain records with no
/// extra fields, comments or data descriptors. package:archive's encoder adds
/// extra fields in some versions, so the CLI writes the records itself. The
/// fixed 1980 entry time keeps the signed payload reproducible; only the
/// [deflated] entry is compressed.
Uint8List plainZip(Map<String, List<int>> entries, {String? deflated}) {
  final out = BytesBuilder(copy: false), directory = BytesBuilder(copy: false);
  for (final entry in entries.entries) {
    final name = utf8.encode(entry.key);
    final method = entry.key == deflated ? 8 : 0;
    final data = method == 8
        ? ZLibEncoder(raw: true).convert(entry.value)
        : entry.value;
    final fields = ByteData(26)
      ..setUint16(0, 20, Endian.little) // version needed
      ..setUint16(2, 0x800, Endian.little) // UTF-8 names
      ..setUint16(4, method, Endian.little)
      ..setUint16(6, 0, Endian.little) // 00:00
      ..setUint16(8, 0x21, Endian.little) // 1980-01-01
      ..setUint32(10, getCrc32(entry.value), Endian.little)
      ..setUint32(14, data.length, Endian.little)
      ..setUint32(18, entry.value.length, Endian.little)
      ..setUint16(22, name.length, Endian.little)
      ..setUint16(24, 0, Endian.little); // extra length
    final common = fields.buffer.asUint8List();
    final central = ByteData(20)
      ..setUint32(12, 0, Endian.little) // external attributes
      ..setUint32(16, out.length, Endian.little);
    out
      ..add([0x50, 0x4b, 0x03, 0x04])
      ..add(common)
      ..add(name)
      ..add(data);
    directory
      ..add([0x50, 0x4b, 0x01, 0x02, 20, 0]) // version made by
      ..add(common)
      // Comment length, disk, internal attributes (zero), then the rest.
      ..add(central.buffer.asUint8List(0, 6))
      ..add(central.buffer.asUint8List(12))
      ..add(name);
  }
  final start = out.length, records = directory.takeBytes();
  out.add(records);
  final end = ByteData(22)
    ..setUint32(0, 0x06054b50, Endian.little)
    ..setUint16(8, entries.length, Endian.little)
    ..setUint16(10, entries.length, Endian.little)
    ..setUint32(12, records.length, Endian.little)
    ..setUint32(16, start, Endian.little);
  out.add(end.buffer.asUint8List());
  return out.takeBytes();
}

/// The patch sequence of a patch made at [time]: seconds since 2025, so
/// patches made on any machine order by when they were made, with no store
/// to ask. Bytecode compiles it into the module, so patch picks it.
int patchSequence(DateTime time) =>
    time.toUtc().difference(DateTime.utc(2025)).inSeconds;

/// When a patch of sequence [seq] was made.
DateTime sequenceTime(int seq) =>
    DateTime.utc(2025).add(Duration(seconds: seq));

/// What patch produces: the archive devices read, complete but for its
/// signature. publish seals it in a signed envelope.
final class PatchDraft {
  PatchDraft._(this.payload, this.manifest);

  static const file = 'patch.draft';

  /// The patch archive exactly as devices read it.
  final Uint8List payload;

  /// Its patch_manifest.json.
  final Map<String, Object?> manifest;

  int get seq => manifest['patch_seq'] as int;
  String get fingerprint => manifest['fingerprint'] as String;

  /// Identifies the draft: publish does not publish one twice.
  String get digest => sha256.convert(payload).toString();

  Future<void> write(String directory) =>
      File(p.join(directory, file)).writeAsBytes(payload, flush: true);

  static Future<PatchDraft> read(String directory) async {
    final path = p.join(directory, file);
    await rejectLinks(path);
    require(
      await File(path).exists(),
      'PATCH_DRAFT_INVALID',
      'No $file in $directory; create it with patch android|ios.',
    );
    require(
      await File(path).length() <= 320 * 1024 * 1024,
      'PATCH_DRAFT_INVALID',
      'Patch draft too large',
    );
    final payload = await File(path).readAsBytes();
    try {
      final entry = ZipDecoder()
          .decodeBytes(payload)
          .findFile('patch_manifest.json');
      final manifest = Map<String, Object?>.from(
        jsonDecode(utf8.decode(entry!.content as List<int>)) as Map,
      );
      final seq = manifest['patch_seq'];
      final fingerprint = manifest['fingerprint'];
      if (manifest['format_version'] != patchFormatVersion ||
          seq is! int ||
          seq <= 0 ||
          seq > 0xffffffff ||
          fingerprint is! String ||
          !RegExp(r'^[0-9a-f]{64}$').hasMatch(fingerprint)) {
        throw const FormatException();
      }
      return PatchDraft._(payload, manifest);
    } catch (_) {
      throw Failure(
        'PATCH_DRAFT_INVALID',
        '$path is not a patch draft of this flutter_patcher.',
      );
    }
  }
}

/// Packs [code] of [kind] with the patch's resources into a draft.
Future<PatchDraft> packPatch({
  required String kind,
  required String code,
  required Map<String, dynamic> metadata,
  Map<String, List<int>> extraEntries = const {},
  List<Map<String, dynamic>> fonts = const [],
  List<Map<String, dynamic>> assets = const [],
}) async {
  final codePath = codePaths[kind];
  require(
    codePath != null,
    'PATCH_PACKAGE_INVALID',
    'Unknown code kind: $kind',
  );
  final bytes = await File(code).readAsBytes();
  require(
    extraEntries.length <= 4094 &&
        extraEntries.values.every((v) => v.length <= 64 * 1024 * 1024) &&
        bytes.length +
                extraEntries.values.fold<int>(0, (n, v) => n + v.length) <=
            256 * 1024 * 1024,
    'PATCH_PACKAGE_INVALID',
    'Patch payload exceeds resource limits',
  );
  for (final row in assets) {
    assetKey(row['key'] as String);
    require(
      row['path'] == 'assets/${row['key']}',
      'PATCH_PACKAGE_INVALID',
      'Asset key/path mismatch',
    );
  }
  for (final row in fonts) {
    require(
      row['family'] is String &&
          (row['family'] as String).isNotEmpty &&
          (row['path'] as String).startsWith('fonts/'),
      'PATCH_PACKAGE_INVALID',
      'Invalid font metadata',
    );
  }
  final listed = <String>{};
  for (final row in [...fonts, ...assets]) {
    final path = row['path'] as String;
    assetKey(path);
    require(
      (path.startsWith('fonts/') || path.startsWith('assets/')) &&
          listed.add(path) &&
          extraEntries.containsKey(path),
      'PATCH_PACKAGE_INVALID',
      'Invalid resource entry',
    );
    final data = extraEntries[path]!;
    require(
      data.length == row['length'] &&
          sha256.convert(data).toString() == row['sha256'],
      'PATCH_PACKAGE_INVALID',
      'Resource metadata does not match bytes',
    );
  }
  require(
    listed.length == extraEntries.length,
    'PATCH_PACKAGE_INVALID',
    'Unlisted resource entry',
  );
  require(
    bytes.isNotEmpty && bytes.length <= 64 * 1024 * 1024,
    'PATCH_PACKAGE_INVALID',
    'Invalid code size',
  );
  final manifest = {
    ...metadata,
    'format_version': patchFormatVersion,
    'code': {
      'kind': kind,
      'path': codePath,
      'length': bytes.length,
      'sha256': sha256.convert(bytes).toString(),
    },
    'fonts': fonts,
    'assets': assets,
  };
  // The Dart bootstrap reads a bytecode archive in place, so every entry is
  // STORED. Native code unpacks a libapp.so once at install: it is deflated,
  // which more than halves an SO patch's download.
  final deflated = kind == 'libapp' ? codePath : null;
  final payload = plainZip({
    codePath!: bytes,
    'patch_manifest.json': utf8.encode(jsonEncode(manifest)),
    ...extraEntries,
  }, deflated: deflated);
  final zip = ZipDecoder().decodeBytes(payload);
  require(
    zip.length == 2 + extraEntries.length &&
        zip.length <= 4096 &&
        zip.every((f) => f.size <= 64 * 1024 * 1024) &&
        zip.every(
          (f) =>
              f.compression ==
              (f.name == deflated
                  ? CompressionType.deflate
                  : CompressionType.none),
        ),
    'PATCH_PACKAGE_INVALID',
    'Only the libapp.so of an SO patch may be compressed',
  );
  return PatchDraft._(payload, manifest);
}
