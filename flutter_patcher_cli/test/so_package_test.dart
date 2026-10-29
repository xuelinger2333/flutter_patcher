import 'dart:convert';
import 'package:archive/archive.dart';
import 'package:test/test.dart';
import 'package:flutter_patcher_cli/src/core.dart';
import 'package:flutter_patcher_cli/src/patch/pipeline.dart';
import 'package:flutter_patcher_cli/src/patch/resources.dart';
import 'package:flutter_patcher_cli/src/patch/so_package.dart';

Archive apk(Map<String, String> assets, Map<String, Object?> manifest) {
  final archive = Archive();
  void add(String name, List<int> bytes) =>
      archive.addFile(ArchiveFile(name, bytes.length, bytes));
  for (final e in assets.entries) {
    add('assets/flutter_assets/${e.key}', utf8.encode(e.value));
  }
  add('assets/flutter_assets/AssetManifest.bin', AssetCodec.encode(manifest));
  return archive;
}

Map<String, dynamic> json(Archive zip, String name) =>
    jsonDecode(utf8.decode(zip.findFile(name)!.content as List<int>));

void main() {
  final manifest = {
    'images/a.png': [
      {'asset': 'images/a.png'}
    ],
  };
  final host = apk({'images/a.png': 'a', 'old.txt': 'gone'}, manifest);
  final release = resourceReceipt(host);
  ({List<int> bytes, List<String> changed}) pack(Archive rebuilt) => soPackage(
      apk: rebuilt,
      libapp: utf8.encode('libapp'),
      release: release,
      version: '3',
      targetVersionCode: 42);

  test('unchanged resources package only libapp.so', () {
    final result = pack(apk({'images/a.png': 'a'}, manifest));
    expect(result.changed, isEmpty);
    final zip = ZipDecoder().decodeBytes(result.bytes);
    expect(zip.map((f) => f.name),
        unorderedEquals(['manifest.json', 'lib/arm64-v8a/libapp.so']));
    expect(json(zip, 'manifest.json')['lib']['arm64-v8a']['path'],
        'lib/arm64-v8a/libapp.so');
    expect(json(zip, 'manifest.json'), isNot(contains('assets')));
  });

  test('changed bytes overlay files; new keys upsert against the host manifest',
      () {
    final next = {
      ...manifest,
      'images/b.png': [
        {'asset': 'images/b.png'}
      ],
    };
    final result = pack(apk({'images/a.png': 'A', 'images/b.png': 'b'}, next));
    expect(result.changed, [
      'asset:images/a.png',
      'asset:images/b.png',
      'key:images/b.png'
    ]);
    final zip = ZipDecoder().decodeBytes(result.bytes);
    final assets = json(zip, 'manifest.json')['assets'] as Map;
    expect(assets['mode'], 'overlay');
    expect((assets['files'] as List).map((f) => f['path']),
        ['images/a.png', 'images/b.png']);
    expect(utf8.decode(zip.findFile('assets/images/a.png')!.content), 'A');
    final ops = json(zip, 'manifest_patch.json');
    expect(ops['baseManifestSize'],
        (release['files'] as Map)['AssetManifest.bin']['length']);
    expect((ops['operations'] as List).single,
        {'op': 'upsert', 'key': 'images/b.png', 'variants': next['images/b.png']});
  });

  test('native changes are rejected; pure Dart dependency changes recorded', () {
    final previous = {
      'app': {'native_files': {}},
      'dart_only': {'version': '1'},
      'plugin': {'native': true, 'version': '1'},
    };
    final changed = <String>[];
    expect(
        nativeInputChanges({
          ...previous,
          'dart_only': {'version': '2'}
        }, previous, 'app', changed),
        isTrue);
    expect(changed, ['dependency:dart_only']);
    expect(
        () => nativeInputChanges({
              ...previous,
              'plugin': {'native': true, 'version': '2'}
            }, previous, 'app', []),
        throwsA(isA<Failure>()
            .having((f) => f.code, 'code', 'PATCH_NATIVE_CHANGE')));
  });
}