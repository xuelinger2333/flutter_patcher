import 'dart:convert';
import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import '../baseline/manifest.dart';
import 'resources.dart';

/// The v2 patch.zip that PatchManager.installPackagePatch materializes: the
/// rebuilt libapp.so plus every flutter asset whose bytes differ from the
/// [release] resource receipt. Assets the release has and the rebuild lacks
/// stay available from the host APK.
({List<int> bytes, List<String> changed}) soPackage(
    {required Archive apk,
    required List<int> libapp,
    required Map release,
    required String version,
    required int targetVersionCode,
    required Map<String, dynamic>? target}) {
  final current = resourceReceipt(apk);
  final oldFiles = release['files'] as Map, newFiles = current['files'] as Map;
  final oldManifest = release['manifest'] as Map,
      newManifest = current['manifest'] as Map;
  final files = [
    for (final path in newFiles.keys.cast<String>())
      if (path != 'AssetManifest.bin' &&
          canonical(newFiles[path]) != canonical(oldFiles[path]))
        path
  ]..sort();
  final keys = [
    for (final key in newManifest.keys.cast<String>())
      if (canonical(newManifest[key]) != canonical(oldManifest[key])) key
  ]..sort();
  List<int> asset(String path) =>
      apk.findFile('assets/flutter_assets/$path')!.content as List<int>;
  final package = Archive();
  void add(String name, List<int> bytes) =>
      package.addFile(ArchiveFile(name, bytes.length, bytes));
  List<int> json(Map<String, dynamic> value) =>
      utf8.encode('${const JsonEncoder.withIndent('  ').convert(value)}\n');
  add(
      'manifest.json',
      json({
        'schemaVersion': 2,
        'version': version,
        'targetVersionCode': targetVersionCode,
        // Signed: publication accepts the patch for this release only.
        if (target != null) 'target': target,
        'lib': {
          'arm64-v8a': {
            'path': 'lib/arm64-v8a/libapp.so',
            'md5': md5.convert(libapp).toString()
          }
        },
        if (files.isNotEmpty || keys.isNotEmpty)
          'assets': {
            'mode': 'overlay',
            'manifestPatch': 'manifest_patch.json',
            'prefix': 'assets/',
            'files': [
              for (final path in files)
                {
                  'path': path,
                  'md5': md5.convert(asset(path)).toString(),
                  'size': asset(path).length
                }
            ]
          }
      }));
  add('lib/arm64-v8a/libapp.so', libapp);
  if (files.isNotEmpty || keys.isNotEmpty) {
    add(
        'manifest_patch.json',
        json({
          'schemaVersion': 1,
          'manifestFormat': 'bin',
          'baseManifestSize': (oldFiles['AssetManifest.bin'] as Map)['length'],
          'operations': [
            for (final key in keys)
              {'op': 'upsert', 'key': key, 'variants': newManifest[key]}
          ]
        }));
    for (final path in files) {
      add('assets/$path', asset(path));
    }
  }
  return (
    bytes: ZipEncoder().encode(package),
    changed: [...files.map((f) => 'asset:$f'), ...keys.map((k) => 'key:$k')]
  );
}