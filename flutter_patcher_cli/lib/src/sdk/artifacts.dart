import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import '../core.dart';

final hex40 = RegExp(r'^[0-9a-f]{40}$');
final hex64 = RegExp(r'^[0-9a-f]{64}$');
final versionPattern = RegExp(r'^\d+\.\d+\.\d+$');

class SdkIdentity {
  final String root, version, engine, dartVersion, framework;
  SdkIdentity(
      this.root, this.version, this.engine, this.dartVersion, this.framework);
  String get dart => p.join(root, 'bin/cache/dart-sdk/bin/dart');
  Map<String, dynamic> toJson() => {
        'flutter_version': version,
        'engine_commit': engine,
        'dart_version': dartVersion,
        'framework_commit': framework
      };
}

void checkManifest(Map<String, dynamic> value, String kind, SdkIdentity sdk) {
  void valid(bool condition, String message) =>
      require(condition, 'ENGINE_MANIFEST_INVALID', message);
  bool hash(dynamic value, RegExp pattern) =>
      value is String && pattern.hasMatch(value);
  valid(value['schema'] is int && value['schema'] == 1,
      'Unknown $kind manifest schema.');
  valid(
      value['flutter_version'] == sdk.version &&
          value['engine_commit'] == sdk.engine,
      '$kind manifest does not match the selected Flutter SDK.');
  valid(hash(value['builder_repo_commit'], hex40), 'Invalid builder commit.');
  final patches = value['patches'];
  valid(patches is List && patches.isNotEmpty, 'Missing patch provenance.');
  final patchNames = <String>{};
  for (final patch in patches as List) {
    valid(
        patch is Map &&
            patch['file'] is String &&
            p.basename(patch['file'] as String) == patch['file'] &&
            hash(patch['sha256'], hex64) &&
            patchNames.add(patch['file'] as String),
        'Invalid patch record.');
  }
  final files = value['files'];
  final expected = kind == 'engine'
      ? {
          'engine': 'libflutter-arm64_v8a-release.jar',
          'gen_snapshot': 'gen_snapshot-linux-x64',
          'embedding': 'flutter_embedding_release.jar'
        }
      : {'tools': 'flutter_patcher_tools-${sdk.version}.dill'};
  require(
      files is List && files.length == expected.length,
      kind == 'engine' ? 'ENGINE_ARTIFACT_MISSING' : 'TOOLS_ARTIFACT_MISSING',
      'Missing required artifact roles.');
  final seen = <String>{};
  for (final file in files as List) {
    valid(file is Map, 'Invalid file entry.');
    final row = file as Map;
    valid(
        row['role'] is String &&
            expected.containsKey(row['role']) &&
            seen.add(row['role'] as String),
        'Unexpected or duplicate role.');
    valid(
        row['name'] == expected[row['role']], 'Unexpected artifact filename.');
    valid(row['size'] is int && row['size'] > 0 && hash(row['sha256'], hex64),
        'Invalid file size/hash.');
    if (row['role'] == 'gen_snapshot') {
      valid(row['host_os'] == 'linux' && row['host_arch'] == 'x64',
          'Wrong gen_snapshot host.');
    }
    if (row['role'] == 'engine' || row['role'] == 'embedding') {
      final name = row['role'] == 'engine'
          ? 'arm64_v8a_release'
          : 'flutter_embedding_release';
      valid(row['maven'] == 'io.flutter:$name:1.0.0-${value['engine_stamp']}',
          'Wrong Maven coordinate.');
    }
    if (row['role'] == 'engine') {
      final contents = row['contents'];
      valid(
          row['abi'] == 'arm64-v8a' && contents is List && contents.length == 1,
          'Wrong engine ABI/contents.');
      final so = (contents as List).single;
      valid(
          so is Map &&
              so['name'] == 'lib/arm64-v8a/libflutter.so' &&
              so['size'] is int &&
              so['size'] > 0 &&
              hash(so['sha256'], hex64),
          'Invalid inner SO record.');
    }
  }
  if (kind == 'engine') {
    valid(
        value['build_id'] is String &&
            RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')
                .hasMatch(value['build_id']),
        'Invalid engine build_id.');
    valid(
        hash(value['engine_stamp'], hex40) &&
            hash(value['depot_tools_rev'], hex40),
        'Invalid engine provenance.');
    valid(
        value['built_at'] is String &&
            RegExp(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$')
                .hasMatch(value['built_at']) &&
            DateTime.tryParse(value['built_at']) != null,
        'Invalid build timestamp.');
    final verify = value['verify'];
    valid(
        verify is Map &&
            verify['snapshot'] == 'passed' &&
            ((verify['device'] == 'passed' &&
                    verify['device_reason'] == null) ||
                (verify['device'] == 'skipped' &&
                    verify['device_reason'] == 'no_android_device')),
        'Engine verification did not pass.');
  } else {
    valid(
        value['dart_version'] == sdk.dartVersion &&
            hash(value['dart_sdk_commit'], hex40),
        'Tools Dart version mismatch.');
  }
}

Future<void> validateFiles(
    String directory, Map<String, dynamic> manifest) async {
  for (final row in manifest['files'] as List) {
    final file = p.join(directory, row['name'] as String);
    await rejectLinks(file);
    require(
        await File(file).exists() &&
            await File(file).length() == row['size'] &&
            await hashFile(file) == row['sha256'],
        'ARTIFACT_HASH_MISMATCH',
        'Size or SHA-256 mismatch: ${row['name']}');
    final bytes = await File(file).readAsBytes();
    if (row['role'] == 'tools') {
      require(bytes.length >= 4 && bytes.take(4).join(',') == '144,171,205,239',
          'ARTIFACT_INVALID', 'Not a kernel dill.');
    } else if (row['role'] == 'gen_snapshot') {
      require(
          bytes.length > 20 &&
              bytes.take(4).join(',') == '127,69,76,70' &&
              bytes[4] == 2 &&
              bytes[5] == 1 &&
              bytes[18] == 62 &&
              bytes[19] == 0,
          'ARTIFACT_INVALID',
          'Not a Linux x64 ELF.');
    } else {
      final archive = ZipDecoder().decodeBytes(bytes);
      if (row['role'] == 'engine') {
        final record = (row['contents'] as List).single;
        final entries = archive.files
            .where((entry) => entry.name == record['name'])
            .toList();
        require(entries.length == 1, 'ARTIFACT_INVALID',
            'Engine jar must contain exactly one matching SO.');
        final content = entries.single.content;
        require(
            content.length == record['size'] &&
                sha256.convert(content).toString() == record['sha256'],
            'ARTIFACT_HASH_MISMATCH',
            'Engine jar inner SO mismatch.');
        require(
            content.length > 20 &&
                content.take(4).join(',') == '127,69,76,70' &&
                content[18] == 183 &&
                content[19] == 0,
            'ARTIFACT_INVALID',
            'Engine SO is not arm64 ELF.');
      } else {
        require(
            archive.files.any((entry) =>
                entry.name == 'io/flutter/embedding/engine/FlutterJNI.class'),
            'ARTIFACT_INVALID',
            'Embedding jar has no FlutterJNI.');
      }
    }
  }
}

class ArtifactStore {
  final String root;
  final Uri base, supportUri;
  final Downloads downloads;
  ArtifactStore(this.root, this.base, this.supportUri, this.downloads);

  Future<void> checkSupport(String version) async {
    require(versionPattern.hasMatch(version), 'ENGINE_ARTIFACT_MISSING',
        'Unsupported Flutter version: $version');
    final key = sha256.convert(utf8.encode(supportUri.toString())).toString();
    final cache = p.join(root, 'support', '$key.txt');
    await rejectLinks(cache);
    Future<List<String>> parse(String file) async {
      final versions = (await File(file).readAsLines())
          .map((line) => line.trim())
          .where((line) => line.isNotEmpty)
          .toList();
      require(
          versions.isNotEmpty &&
              versions.every(versionPattern.hasMatch) &&
              versions.toSet().length == versions.length,
          'ENGINE_MANIFEST_INVALID',
          'Invalid supported_versions.txt');
      return versions;
    }

    List<String>? versions;
    if (await File(cache).exists()) {
      try {
        versions = await parse(cache);
      } on Failure {
        if (downloads.offline) rethrow;
      }
    }
    if (versions == null ||
        (!versions.contains(version) && !downloads.offline)) {
      final staging = temporaryName(cache);
      await downloads.fetch(supportUri, staging, maxBytes: 65536);
      versions = await parse(staging);
      if (await File(cache).exists()) await quarantine(cache);
      await File(staging).rename(cache);
    }
    require(versions.contains(version), 'ENGINE_ARTIFACT_MISSING',
        'Flutter $version is not supported. Supported versions: ${versions.join(', ')}');
  }

  Future<Map<String, dynamic>> obtain(String kind, SdkIdentity sdk) async {
    final directory = p.join(root, 'artifacts', sdk.version, kind);
    await rejectLinks(directory);
    final source =
        '${base.toString().replaceAll(RegExp(r'/+$'), '')}/flutter-${sdk.version}/';
    final manifestName = '$kind.manifest.json';
    if (await Directory(directory).exists()) {
      try {
        final provenance = await readObject(p.join(directory, 'source.json'));
        require(provenance['url'] == source, 'CACHE_INVALID',
            'Cached source changed.');
        final manifest = await readObject(p.join(directory, manifestName));
        checkManifest(manifest, kind, sdk);
        await validateFiles(directory, manifest);
        return manifest;
      } catch (_) {
        if (downloads.offline) rethrow;
        await quarantine(directory);
      }
    }
    final missing =
        kind == 'engine' ? 'ENGINE_ARTIFACT_MISSING' : 'TOOLS_ARTIFACT_MISSING';
    final staging = temporaryName(directory);
    await downloads.fetch(
        Uri.parse('$source$manifestName'), p.join(staging, manifestName),
        missingCode: missing, maxBytes: 1024 * 1024);
    final manifest = await readObject(p.join(staging, manifestName));
    checkManifest(manifest, kind, sdk);
    for (final file in manifest['files'] as List) {
      await downloads.fetch(Uri.parse('$source${file['name']}'),
          p.join(staging, file['name'] as String),
          missingCode: missing, maxBytes: file['size'] as int);
    }
    await validateFiles(staging, manifest);
    await writeObject(p.join(staging, 'source.json'), {'url': source});
    await Directory(staging).rename(directory);
    return manifest;
  }

  String file(SdkIdentity sdk, String kind, String name) =>
      p.join(root, 'artifacts', sdk.version, kind, name);
}
