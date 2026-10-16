import 'dart:io';
import 'dart:convert';
import 'package:test/test.dart';
import 'package:path/path.dart' as p;
import 'package:crypto/crypto.dart';
import 'package:flutter_patcher_cli/src/patch/resources.dart';
import 'package:flutter_patcher_cli/src/patch/package.dart';
import 'package:flutter_patcher_cli/src/core.dart';

void main() {
  test('resource manifest mismatch is rejected before signing', () async {
    final dir = await Directory.systemTemp.createTemp('resources-package-');
    addTearDown(() => dir.delete(recursive: true));
    final module = File(p.join(dir.path, 'module.bc'));
    await module.writeAsBytes([1]);
    await expectLater(
        packPatch(
            module: module.path,
            work: dir.path,
            metadata: {},
            key: [],
            commands: Commands(dir.path),
            extraEntries: {
              'assets/a': [1]
            },
            assets: [
              {'key': '../a', 'path': 'assets/a', 'length': 1, 'sha256': 'bad'}
            ]),
        throwsA(isA<Failure>()));
    await expectLater(
        packPatch(
            module: module.path,
            work: dir.path,
            metadata: {},
            key: [],
            commands: Commands(dir.path),
            extraEntries: {
              'assets/a': [1]
            },
            assets: [
              {'key': 'a', 'path': 'assets/a', 'length': 1, 'sha256': 'bad'}
            ]),
        throwsA(isA<Failure>()));
  });
  test('manifest codec roundtrip with image variants and rejects bad input',
      () {
    final data = {
      'a': [
        {'asset': 'a'},
        {'asset': '2.0x/a', 'dpr': 2.0}
      ]
    };
    expect(AssetCodec.decode(AssetCodec.encode(data)), data);
    expect(() => AssetCodec.decode([13, 1, 7]), throwsA(isA<Failure>()));
    expect(() => AssetCodec.decode([...AssetCodec.encode(data), 0]),
        throwsA(isA<Failure>()));
    for (final key in ['../a', '/a', 'a\\b', 'a//b', 'C:x', 'a/./b']) {
      expect(() => assetKey(key), throwsA(isA<Failure>()));
    }
  });
  test('changed image brings variants and merges only selected metadata',
      () async {
    final dir = await Directory.systemTemp.createTemp('resources-');
    addTearDown(() => dir.delete(recursive: true));
    final manifest = {
      'a': [
        {'asset': 'a'},
        {'asset': '2.0x/a', 'dpr': 2.0}
      ],
      'b': [
        {'asset': 'b'}
      ]
    };
    for (final key in ['a', '2.0x/a', 'b']) {
      final file = File(p.join(dir.path, key));
      await file.parent.create(recursive: true);
      await file.writeAsString(key);
    }
    await File(p.join(dir.path, 'AssetManifest.bin'))
        .writeAsBytes(AssetCodec.encode(manifest));
    final baseline = {
      'schema': 1,
      'manifest': manifest,
      'files': {
        for (final key in ['a', '2.0x/a', 'b'])
          key: {'sha256': sha256.convert(utf8.encode(key)).toString()}
      }
    };
    final unchanged =
        PatchResources(dir.path, dir.path, Commands(dir.path), dir.path);
    await unchanged.collect(baseline, []);
    expect(unchanged.assets, isEmpty);
    await File(p.join(dir.path, 'a')).writeAsString('new');
    final patch =
        PatchResources(dir.path, dir.path, Commands(dir.path), dir.path);
    await patch.collectFonts([
      {'fontFamily': null, 'codePoint': 128842}
    ], []);
    expect(
        patch.fonts, isEmpty); // System fallback, not a missing bundled font.
    await patch.collect(baseline, []);
    expect(patch.assets.map((a) => a['key']).toSet(),
        {'a', '2.0x/a', 'AssetManifest.bin'});
    expect(AssetCodec.decode(patch.entries['assets/AssetManifest.bin']!),
        manifest);
    final bad =
        PatchResources(dir.path, dir.path, Commands(dir.path), dir.path);
    await expectLater(
        bad.collect(baseline, ['a', 'a']), throwsA(isA<Failure>()));
    await File(p.join(dir.path, 'AssetManifest.bin'))
        .writeAsBytes(AssetCodec.encode({'b': manifest['b']}));
    await expectLater(bad.collect(baseline, []), throwsA(isA<Failure>()));
  });
  test('dynamic or missing icon fonts cannot silently disappear', () async {
    final dir = await Directory.systemTemp.createTemp('resources-fonts-');
    addTearDown(() => dir.delete(recursive: true));
    final patch =
        PatchResources(dir.path, dir.path, Commands(dir.path), dir.path);
    await expectLater(patch.collectFonts([], [{}]), throwsA(isA<Failure>()));
    await expectLater(
        patch.collectFonts([
          {'fontFamily': 'Absent', 'codePoint': 65}
        ], []),
        throwsA(isA<Failure>()));
  });
}
