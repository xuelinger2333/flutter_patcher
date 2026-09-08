import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import '../core.dart';
import '../baseline/manifest.dart';

void assetKey(String key) {
  require(
      key.isNotEmpty &&
          !key.contains('\\') &&
          !key.contains(':') &&
          !key.contains('\u0000') &&
          !key.startsWith('/') &&
          key.split('/').every((s) => s.isNotEmpty && s != '.' && s != '..'),
      'PATCH_ASSET_INVALID',
      'Unsafe asset key: $key');
}

Future<List<String>> readObjectFontSources(String bundle) async {
  final file = File(p.join(bundle, 'FontManifest.json'));
  if (!await file.exists()) return [];
  final rows = jsonDecode(await file.readAsString()) as List;
  return [
    for (final row in rows)
      if (row['family'] != 'MaterialIcons')
        for (final font in row['fonts'] as List) font['asset'] as String
  ];
}

/// Flutter AssetManifest.bin uses StandardMessageCodec. Only its data types
/// are accepted, with bounded lengths, nesting, exact EOF and duplicate checks.
class AssetCodec {
  AssetCodec(this.bytes);
  final Uint8List bytes;
  int offset = 0;
  ByteData get data => ByteData.sublistView(bytes);
  void need(int count) {
    require(count >= 0 && offset + count <= bytes.length, 'PATCH_ASSET_INVALID',
        'Truncated asset manifest');
  }

  int byte() {
    need(1);
    return bytes[offset++];
  }

  int size() {
    final n = byte();
    if (n < 254) return n;
    need(n == 254 ? 2 : 4);
    final value = n == 254
        ? data.getUint16(offset, Endian.host)
        : data.getUint32(offset, Endian.host);
    offset += n == 254 ? 2 : 4;
    require(value <= 65536, 'PATCH_ASSET_INVALID',
        'Asset manifest collection too large');
    return value;
  }

  Object? read([int depth = 0]) {
    require(
        depth < 16, 'PATCH_ASSET_INVALID', 'Asset manifest nesting too deep');
    switch (byte()) {
      case 0:
        return null;
      case 3:
        need(4);
        final n = data.getInt32(offset, Endian.host);
        offset += 4;
        return n;
      case 6:
        offset = (offset + 7) & ~7;
        need(8);
        final n = data.getFloat64(offset, Endian.host);
        offset += 8;
        return n;
      case 7:
        final n = size();
        need(n);
        final s = utf8.decode(bytes.sublist(offset, offset + n));
        offset += n;
        return s;
      case 12:
        return List.generate(size(), (_) => read(depth + 1));
      case 13:
        final result = <String, Object?>{}, n = size();
        for (var i = 0; i < n; i++) {
          final key = read(depth + 1);
          require(key is String && !result.containsKey(key),
              'PATCH_ASSET_INVALID', 'Duplicate/invalid manifest key');
          result[key as String] = read(depth + 1);
        }
        return result;
      default:
        throw Failure(
            'PATCH_ASSET_INVALID', 'Unsupported asset manifest value');
    }
  }

  static Map<String, dynamic> decode(List<int> bytes) {
    final reader = AssetCodec(Uint8List.fromList(bytes)),
        result = reader.read();
    require(result is Map && reader.offset == bytes.length,
        'PATCH_ASSET_INVALID', 'Invalid asset manifest');
    return Map<String, dynamic>.from(result as Map);
  }

  static List<int> encode(Object? value) {
    final out = <int>[];
    void size(int n) {
      require(n <= 65536, 'PATCH_ASSET_INVALID',
          'Asset manifest collection too large');
      if (n < 254) {
        out.add(n);
      } else {
        final b = ByteData(n <= 65535 ? 2 : 4);
        if (n <= 65535) {
          b.setUint16(0, n, Endian.host);
          out.add(254);
        } else {
          b.setUint32(0, n, Endian.host);
          out.add(255);
        }
        out.addAll(b.buffer.asUint8List());
      }
    }

    void write(Object? v) {
      if (v == null) {
        out.add(0);
      } else if (v is String) {
        final s = utf8.encode(v);
        out.add(7);
        size(s.length);
        out.addAll(s);
      } else if (v is int) {
        out.add(3);
        final b = ByteData(4)..setInt32(0, v, Endian.host);
        out.addAll(b.buffer.asUint8List());
      } else if (v is double) {
        out.add(6);
        while (out.length % 8 != 0) {
          out.add(0);
        }
        final b = ByteData(8)..setFloat64(0, v, Endian.host);
        out.addAll(b.buffer.asUint8List());
      } else if (v is List) {
        out.add(12);
        size(v.length);
        for (final x in v) {
          write(x);
        }
      } else if (v is Map) {
        out.add(13);
        size(v.length);
        for (final k in v.keys.toList()..sort()) {
          write(k);
          write(v[k]);
        }
      } else {
        throw Failure('PATCH_ASSET_INVALID', 'Unsupported manifest value');
      }
    }

    write(value);
    return out;
  }
}

Future<Map<String, dynamic>> resourceReceipt(String apk) async {
  final archive = ZipDecoder().decodeBytes(await File(apk).readAsBytes());
  final files = <String, dynamic>{};
  Map<String, dynamic> manifest = {};
  for (final f in archive) {
    if (!f.isFile || !f.name.startsWith('assets/flutter_assets/')) continue;
    final key = f.name.substring('assets/flutter_assets/'.length);
    assetKey(key);
    final bytes = f.content as List<int>;
    require(
        !files.containsKey(key), 'PATCH_ASSET_INVALID', 'Duplicate APK asset');
    files[key] = {
      'sha256': sha256.convert(bytes).toString(),
      'length': bytes.length
    };
    if (key == 'AssetManifest.bin') manifest = AssetCodec.decode(bytes);
  }
  return {'schema': 1, 'files': files, 'manifest': manifest};
}

class PatchResources {
  PatchResources(this.bundle, this.work, this.commands, this.sdk);
  final String bundle, work, sdk;
  final Commands commands;
  final Map<String, List<int>> entries = {};
  final List<Map<String, dynamic>> assets = [], fonts = [];

  Future<List<int>> read(String key) async {
    assetKey(key);
    final file = File(p.join(bundle, key));
    await rejectLinks(file.path);
    require(await file.exists() && await file.length() <= 64 * 1024 * 1024,
        'PATCH_ASSET_INVALID', 'Missing or oversized resource: $key');
    return file.readAsBytes();
  }

  void addAsset(String key, List<int> bytes) {
    assetKey(key);
    final path = 'assets/$key';
    require(!entries.containsKey(path), 'PATCH_ASSET_INVALID',
        'Duplicate resource: $key');
    entries[path] = bytes;
    assets.add({
      'key': key,
      'path': path,
      'length': bytes.length,
      'sha256': sha256.convert(bytes).toString()
    });
  }

  Future<void> collect(
      Map<String, dynamic> baseline, List<String> requested) async {
    require(
        baseline['schema'] == 1 &&
            baseline['files'] is Map &&
            baseline['manifest'] is Map,
        'PATCH_BASELINE_INCOMPATIBLE',
        'Baseline lacks resource inventory; rebuild host');
    final old = Map<String, dynamic>.from(baseline['manifest'] as Map);
    final current = AssetCodec.decode(await read('AssetManifest.bin'));
    Set<String> variants(Map<String, dynamic> manifest, String key) {
      final rows = manifest[key];
      require(
          rows is List, 'PATCH_ASSET_INVALID', 'Asset is not declared: $key');
      return {key, for (final row in rows as List) row['asset'] as String};
    }

    // Overlays cannot delete a resource or an image variant from the host.
    for (final key in old.keys) {
      require(
          current.containsKey(key) &&
              variants(current, key).containsAll(variants(old, key)),
          'PATCH_ASSET_DELETE_UNSUPPORTED',
          'Resource deletion requires a new host: $key');
    }
    final selected = <String>{};
    require(requested.toSet().length == requested.length, 'PATCH_ASSET_INVALID',
        'Duplicate --assets key');
    for (final key in requested) {
      assetKey(key);
      variants(current, key);
      selected.add(key);
    }
    if (requested.isEmpty) {
      for (final key in current.keys) {
        for (final variant in variants(current, key)) {
          final bytes = await read(variant);
          if ((baseline['files'] as Map)[variant]?['sha256'] !=
              sha256.convert(bytes).toString()) {
            selected.add(key);
          }
        }
        if (canonical(old[key]) != canonical(current[key])) selected.add(key);
      }
    }
    final keys = {for (final k in selected) ...variants(current, k)}.toList()
      ..sort();
    for (final key in keys) {
      addAsset(key, await read(key));
    }
    if (selected.isNotEmpty) {
      final merged = {...old, for (final key in selected) key: current[key]};
      addAsset('AssetManifest.bin', AssetCodec.encode(merged));
    }
  }

  Future<void> collectFonts(
      List<dynamic> icons, List<dynamic> dynamicIcons) async {
    require(dynamicIcons.isEmpty, 'PATCH_DYNAMIC_ICON',
        'Non-constant IconData cannot be subset safely');
    final fontFile = File(p.join(bundle, 'FontManifest.json'));
    final definitions = await fontFile.exists()
        ? jsonDecode(await fontFile.readAsString()) as List
        : <dynamic>[];
    final groups = <String, Set<int>>{};
    final fallbackFamilies = <String>{};
    for (final raw in icons) {
      final family = raw['fontFamily'],
          package = raw['fontPackage'],
          point = raw['codePoint'];
      require(
          (family == null || family is String) &&
              point is int &&
              point >= 0 &&
              point <= 0x10ffff,
          'FONT_SUBSET_FAILED',
          'IconData must identify a valid code point');
      for (final fallback in raw['fontFamilyFallback'] as List? ?? []) {
        fallbackFamilies.add(package == null
            ? fallback as String
            : 'packages/$package/$fallback');
      }
      // Icon builds a non-inheriting TextStyle. A null family uses system
      // fallback (e.g. Flutter's U+1F74A debug icon), not a bundled icon font.
      if (family == null) continue;
      final name =
          package == null ? family as String : 'packages/$package/$family';
      groups.putIfAbsent(name, () => {}).add(point as int);
    }
    final found = <String>{};
    for (final definition in definitions) {
      final family = definition['family'] as String,
          sources = definition['fonts'] as List;
      // Only the SDK's dedicated Material icon face is known to be icon-only.
      // Custom/package families may also be used by Text and must remain whole.
      final points = fallbackFamilies.contains(family) ||
              family != 'MaterialIcons' ||
              sources.length != 1 ||
              sources.single['asset'] != 'fonts/MaterialIcons-Regular.otf'
          ? null
          : groups[family];
      // Framework material font is needed only when referenced. Text fonts are
      // carried whole because IconData does not describe their glyph usage.
      if (family == 'MaterialIcons' &&
          !groups.containsKey(family) &&
          !fallbackFamilies.contains(family)) {
        continue;
      }
      found.add(family);
      require(points == null || sources.length == 1, 'FONT_SUBSET_FAILED',
          'Ambiguous icon font family: $family');
      for (var i = 0; i < sources.length; i++) {
        final source = sources[i]['asset'] as String;
        var bytes = await read(source);
        if (points != null) {
          final output = p.join(work, 'font-${fonts.length}.otf');
          final binary =
              p.join(sdk, 'bin/cache/artifacts/engine/linux-x64/font-subset');
          require(await File(binary).exists(), 'FONT_SUBSET_FAILED',
              'SDK font-subset is missing');
          await commands.run(binary, [output, p.join(bundle, source)],
              inputBytes: utf8.encode((points.toList()..sort()).join(' ')),
              code: 'FONT_SUBSET_FAILED');
          require(
              await File(output).exists() && await File(output).length() > 0,
              'FONT_SUBSET_FAILED',
              'font-subset produced no font');
          bytes = await File(output).readAsBytes();
        }
        final path =
            'fonts/${sha256.convert(utf8.encode('$family/$i')).toString()}.otf';
        entries[path] = bytes;
        fonts.add({
          'family': family,
          'path': path,
          'length': bytes.length,
          'sha256': sha256.convert(bytes).toString(),
          if (points != null) 'codepoints': points.length,
          'subset': points != null
        });
      }
    }
    require(found.containsAll(groups.keys), 'FONT_SUBSET_FAILED',
        'Referenced font is absent from Flutter bundle');
  }
}
