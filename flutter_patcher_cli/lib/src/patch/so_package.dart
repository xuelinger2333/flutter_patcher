import 'dart:convert';
import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import '../baseline/manifest.dart';
import 'resources.dart';

/// A v2 patch.zip as PatchManager.installPackagePatch reads it: [libapp] for
/// [abi], overlay [files] (paths relative to flutter_assets) and AssetManifest
/// [upserts] (key to variants) against a host manifest of [baseManifestSize]
/// bytes. [target] is the signed release binding of an authenticated patch.
List<int> v2Package(
    {required List<int> libapp,
    String abi = 'arm64-v8a',
    Map<String, List<int>> files = const {},
    Map<String, Object?> upserts = const {},
    int baseManifestSize = 0,
    required String version,
    required int targetVersionCode,
    Map<String, dynamic>? target}) {
  final assets = files.isNotEmpty || upserts.isNotEmpty;
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
          abi: {'path': 'lib/$abi/libapp.so', 'md5': md5.convert(libapp).toString()}
        },
        if (assets)
          'assets': {
            'mode': 'overlay',
            'manifestPatch': 'manifest_patch.json',
            'prefix': 'assets/',
            'files': [
              for (final e in files.entries)
                {'path': e.key, 'md5': md5.convert(e.value).toString(), 'size': e.value.length}
            ]
          }
      }));
  add('lib/$abi/libapp.so', libapp);
  if (assets) {
    add(
        'manifest_patch.json',
        json({
          'schemaVersion': 1,
          'manifestFormat': 'bin',
          'baseManifestSize': baseManifestSize,
          'operations': [
            for (final e in upserts.entries)
              {'op': 'upsert', 'key': e.key, 'variants': e.value}
          ]
        }));
    for (final e in files.entries) {
      add('assets/${e.key}', e.value);
    }
  }
  return ZipEncoder().encode(package, modified: DateTime.utc(1980));
}

/// An SO patch: the rebuilt libapp.so plus every flutter asset whose bytes
/// differ from the [release] resource receipt. Assets the release has and the
/// rebuild lacks stay available from the host APK.
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
  return (
    bytes: v2Package(
        libapp: libapp,
        files: {
          for (final path in files)
            path: apk.findFile('assets/flutter_assets/$path')!.content as List<int>
        },
        upserts: {for (final key in keys) key: newManifest[key]},
        baseManifestSize: files.isEmpty && keys.isEmpty
            ? 0
            : (oldFiles['AssetManifest.bin'] as Map)['length'] as int,
        version: version,
        targetVersionCode: targetVersionCode,
        target: target),
    changed: [...files.map((f) => 'asset:$f'), ...keys.map((k) => 'key:$k')]
  );
}