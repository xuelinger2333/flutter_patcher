import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import '../core.dart';
import 'host.dart';

final hex40 = RegExp(r'^[0-9a-f]{40}$');
final hex64 = RegExp(r'^[0-9a-f]{64}$');
final versionPattern = RegExp(r'^\d+\.\d+\.\d+$');

class SdkIdentity {
  final String root, version, engine, dartVersion, framework;
  final HostIdentity host;
  SdkIdentity(
      this.root, this.version, this.engine, this.dartVersion, this.framework,
      {HostIdentity? host})
      : host = host ?? HostIdentity.current();
  String get dart => host.dartBinary(root);
  String get dartAotRuntime => host.dartAotRuntime(root);
  String get flutter => host.flutterLauncher(root);
  Map<String, dynamic> toJson() => {
        'flutter_version': version,
        'engine_commit': engine,
        'dart_version': dartVersion,
        'framework_commit': framework
      };
}

/// A well-formed `verify` block: snapshot/device states with a skip reason
/// only when skipped. Pending states are allowed here (other hosts' rows).
bool verificationShape(dynamic verify, {String platform = 'android'}) =>
    verify is Map &&
    const ['pending', 'passed'].contains(verify['snapshot']) &&
    ((const ['pending', 'passed'].contains(verify['device']) &&
            verify['device_reason'] == null) ||
        (verify['device'] == 'skipped' &&
            verify['device_reason'] == 'no_${platform}_device'));

bool verificationPassed(dynamic verify, {String platform = 'android'}) =>
    verificationShape(verify, platform: platform) &&
    verify['snapshot'] == 'passed' &&
    verify['device'] != 'pending';

/// Rows this host downloads and checks: everything except gen_snapshots
/// built for other hosts.
Iterable<Map> hostFiles(Map<String, dynamic> manifest, HostIdentity host) =>
    (manifest['files'] as List).cast<Map>().where((row) =>
        row['role'] != 'gen_snapshot' ||
        '${row['host_os']}-${row['host_arch']}' == host.key);

/// iOS engine release files. The zip holds the whole Flutter.xcframework:
/// the patched device slice and the stock simulator slice.
const iosFrameworkZip = 'Flutter.xcframework.zip';
const iosFrameworkBinary =
    'Flutter.xcframework/ios-arm64/Flutter.framework/Flutter';

/// gen_snapshot that runs on macos-arm64 and emits iOS arm64 code.
const iosGenSnapshot = 'gen_snapshot_ios-darwin-arm64';

void _checkSource(Map<String, dynamic> value, String kind, SdkIdentity sdk,
    void Function(bool, String) valid) {
  valid(
      value['flutter_version'] == sdk.version &&
          value['engine_commit'] == sdk.engine,
      '$kind manifest does not match the selected Flutter SDK.');
  valid(_hash(value['builder_repo_commit'], hex40), 'Invalid builder commit.');
  final patches = value['patches'];
  valid(patches is List && patches.isNotEmpty, 'Missing patch provenance.');
  final patchNames = <String>{};
  for (final patch in patches as List) {
    valid(
        patch is Map &&
            patch['file'] is String &&
            p.basename(patch['file'] as String) == patch['file'] &&
            _hash(patch['sha256'], hex64) &&
            patchNames.add(patch['file'] as String),
        'Invalid patch record.');
  }
}

void _checkBuild(
    Map<String, dynamic> value, void Function(bool, String) valid) {
  valid(
      value['build_id'] is String &&
          RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')
              .hasMatch(value['build_id']),
      'Invalid engine build_id.');
  valid(_hash(value['depot_tools_rev'], hex40), 'Invalid engine provenance.');
  valid(
      value['built_at'] is String &&
          RegExp(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$')
              .hasMatch(value['built_at']) &&
          DateTime.tryParse(value['built_at']) != null,
      'Invalid build timestamp.');
}

bool _hash(dynamic value, RegExp pattern) =>
    value is String && pattern.hasMatch(value);

/// The iOS engine release (schema 1) of a Flutter version: same version,
/// engine and patch set as its Android release, built on macos-arm64.
void _checkIosEngine(Map<String, dynamic> value, SdkIdentity sdk) {
  void valid(bool condition, String message) =>
      require(condition, 'ENGINE_MANIFEST_INVALID', message);
  valid(value['schema'] == 1, 'Unknown engine-ios manifest schema.');
  _checkSource(value, 'engine-ios', sdk, valid);
  _checkBuild(value, valid);
  valid(verificationPassed(value['verify'], platform: 'ios'),
      'iOS engine verification did not pass.');
  final files = value['files'];
  valid(
      files is List && files.every((row) => row is Map), 'Invalid file list.');
  final rows = {
    for (final row in (files as List).cast<Map>()) row['role']: row
  };
  require(
      files.length == 2 &&
          rows.length == 2 &&
          rows.containsKey('framework') &&
          rows.containsKey('gen_snapshot'),
      'ENGINE_ARTIFACT_MISSING',
      'Missing required artifact roles.');
  for (final row in rows.values) {
    valid(row['size'] is int && row['size'] > 0 && _hash(row['sha256'], hex64),
        'Invalid file size/hash.');
  }
  final framework = rows['framework']!, snapshot = rows['gen_snapshot']!;
  valid(
      framework['name'] == iosFrameworkZip &&
          snapshot['name'] == iosGenSnapshot,
      'Unexpected artifact filename.');
  valid(snapshot['host_os'] == 'macos' && snapshot['host_arch'] == 'arm64',
      'Unsupported gen_snapshot host.');
  final contents = framework['contents'];
  valid(contents is List && contents.length == 1, 'Wrong framework contents.');
  final binary = (contents as List).single;
  valid(
      binary is Map &&
          binary['name'] == iosFrameworkBinary &&
          binary['size'] is int &&
          binary['size'] > 0 &&
          _hash(binary['sha256'], hex64),
      'Invalid inner framework record.');
}

/// Rejects a framework zip that could write outside Flutter.xcframework or
/// whose device binary is not the recorded arm64 Mach-O.
void checkFrameworkArchive(Archive archive, Map record) {
  for (final entry in archive.files) {
    final parts = entry.name.split('/');
    require(
        !entry.isSymbolicLink &&
            parts.first == 'Flutter.xcframework' &&
            !entry.name.contains(r'\') &&
            !parts.any((part) => part == '..' || part == '.'),
        'ARTIFACT_INVALID',
        'Unsafe framework archive entry: ${entry.name}');
  }
  require(
      archive.files
          .any((entry) => entry.name == 'Flutter.xcframework/Info.plist'),
      'ARTIFACT_INVALID',
      'Framework archive has no xcframework Info.plist.');
  final binaries =
      archive.files.where((entry) => entry.name == record['name']).toList();
  require(binaries.length == 1, 'ARTIFACT_INVALID',
      'Framework archive must contain exactly one device binary.');
  final content = binaries.single.content;
  require(
      content.length == record['size'] &&
          sha256.convert(content).toString() == record['sha256'],
      'ARTIFACT_HASH_MISMATCH',
      'Framework device binary mismatch.');
  require(
      content.length > 8 &&
          content.take(8).join(',') == '207,250,237,254,12,0,0,1',
      'ARTIFACT_INVALID',
      'Framework device binary is not arm64 Mach-O.');
}

void checkManifest(Map<String, dynamic> value, String kind, SdkIdentity sdk) {
  if (kind == 'engine-ios') return _checkIosEngine(value, sdk);
  void valid(bool condition, String message) =>
      require(condition, 'ENGINE_MANIFEST_INVALID', message);
  const hash = _hash;
  // Engine schema 2 lists one gen_snapshot per build host; schema 1
  // releases carry only linux-x64. Tools manifests stay at schema 1.
  final schema = value['schema'];
  valid(schema is int && (schema == 1 || (kind == 'engine' && schema == 2)),
      'Unknown $kind manifest schema.');
  _checkSource(value, kind, sdk, valid);
  final files = value['files'];
  final expected = kind == 'engine'
      ? {
          'engine': 'libflutter-arm64_v8a-release.jar',
          'embedding': 'flutter_embedding_release.jar'
        }
      : {'tools': 'flutter_patcher_tools-${sdk.version}.dill'};
  final missing =
      kind == 'engine' ? 'ENGINE_ARTIFACT_MISSING' : 'TOOLS_ARTIFACT_MISSING';
  valid(files is List, 'Invalid file list.');
  if (kind == 'tools') {
    require((files as List).length == 1, missing,
        'Missing required artifact roles.');
  }
  final seen = <String>{};
  final snapshotHosts = <String>[];
  Map? mine;
  for (final file in files as List) {
    valid(file is Map, 'Invalid file entry.');
    final row = file as Map;
    if (kind == 'engine' && row['role'] == 'gen_snapshot') {
      final os = row['host_os'], arch = row['host_arch'];
      valid(
          os is String &&
              arch is String &&
              HostIdentity.implemented.contains('$os-$arch') &&
              !snapshotHosts.contains('$os-$arch'),
          'Unsupported or duplicate gen_snapshot host.');
      final rowHost = HostIdentity(os as String, arch as String);
      snapshotHosts.add(rowHost.key);
      valid(rowHost.key == 'linux-x64' || schema == 2,
          'Unsupported gen_snapshot host.');
      valid(row['name'] == rowHost.genSnapshotArtifact,
          'Unexpected artifact filename.');
      if (schema == 2) {
        valid(
            row['built_at'] is String &&
                DateTime.tryParse(row['built_at'] as String) != null &&
                hash(row['builder_repo_commit'], hex40) &&
                verificationShape(row['verify']),
            'Invalid gen_snapshot record.');
      }
      if (rowHost.key == sdk.host.key) mine = row;
    } else {
      valid(
          row['role'] is String &&
              expected.containsKey(row['role']) &&
              seen.add(row['role'] as String),
          'Unexpected or duplicate role.');
      valid(row['name'] == expected[row['role']],
          'Unexpected artifact filename.');
    }
    valid(row['size'] is int && row['size'] > 0 && hash(row['sha256'], hex64),
        'Invalid file size/hash.');
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
    require(seen.length == expected.length && snapshotHosts.isNotEmpty, missing,
        'Missing required artifact roles.');
    valid(snapshotHosts.contains('linux-x64'), 'Missing primary gen_snapshot.');
    // A release built for other hosts is not corrupt; it simply has nothing
    // for this machine.
    require(
        mine != null,
        missing,
        'Engine release has no gen_snapshot for host ${sdk.host.key} '
        '(release provides ${snapshotHosts.join(', ')}).');
    if (schema == 2) {
      valid(verificationPassed(mine!['verify']),
          'gen_snapshot verification for ${sdk.host.key} did not pass.');
    }
    _checkBuild(value, valid);
    valid(hash(value['engine_stamp'], hex40), 'Invalid engine provenance.');
    valid(verificationPassed(value['verify']),
        'Engine verification did not pass.');
  } else {
    valid(
        value['dart_version'] == sdk.dartVersion &&
            hash(value['dart_sdk_commit'], hex40),
        'Tools Dart version mismatch.');
  }
}

Future<void> validateFiles(String directory, Map<String, dynamic> manifest,
    {HostIdentity? host}) async {
  host ??= HostIdentity.current();
  for (final row in hostFiles(manifest, host)) {
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
      require(host.isNativeExecutable(bytes), 'ARTIFACT_INVALID',
          'Not a ${host.key} executable.');
    } else if (row['role'] == 'framework') {
      checkFrameworkArchive(ZipDecoder().decodeBytes(bytes),
          (row['contents'] as List).single as Map);
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
      await File(staging).renameRetry(cache);
    }
    require(versions.contains(version), 'ENGINE_ARTIFACT_MISSING',
        'Flutter $version is not supported. Supported versions: ${versions.join(', ')}');
  }

  Future<Map<String, dynamic>> obtain(String kind, SdkIdentity sdk,
      {bool refresh = false}) async {
    require(!refresh || (kind == 'tools' && !downloads.offline),
        'CONFIG_INVALID', 'Tool refresh requires online mode.');
    final directory = _directory(sdk, kind);
    await rejectLinks(directory);
    if (kind == 'engine') await _migrateLegacyEngineCache(sdk, directory);
    final source =
        '${base.toString().replaceAll(RegExp(r'/+$'), '')}/flutter-${sdk.version}/';
    final manifestName = '$kind.manifest.json';
    final missing = kind.startsWith('engine')
        ? 'ENGINE_ARTIFACT_MISSING'
        : 'TOOLS_ARTIFACT_MISSING';
    final staging = temporaryName(directory);
    var outdated = false;
    if (!refresh && await Directory(directory).exists()) {
      Map<String, dynamic>? cached;
      try {
        final provenance = await readObject(p.join(directory, 'source.json'));
        require(provenance['url'] == source, 'CACHE_INVALID',
            'Cached source changed.');
        final manifest = await readObject(p.join(directory, manifestName));
        checkManifest(manifest, kind, sdk);
        await validateFiles(directory, manifest, host: sdk.host);
        cached = manifest;
      } catch (_) {
        if (downloads.offline) rethrow;
        await quarantine(directory);
      }
      if (cached != null) {
        if (downloads.offline) return cached;
        // A release can be rebuilt under the same Flutter version (a new
        // engine patch, fixed tools): the small manifest says whether the
        // cached files are still the source's.
        try {
          await downloads.fetch(
              Uri.parse('$source$manifestName'), p.join(staging, manifestName),
              missingCode: missing, maxBytes: 1024 * 1024);
        } catch (error) {
          // Unreachable or failing source: the verified cache still works.
          await _discard(staging);
          stderr.writeln('WARNING: ARTIFACT_CHECK_SKIPPED: using cached $kind '
              'artifacts; cannot reach $source ($error)');
          return cached;
        }
        if (await _sameBytes(
            p.join(staging, manifestName), p.join(directory, manifestName))) {
          await _discard(staging);
          return cached;
        }
        outdated = true;
      }
    }
    if (!outdated) {
      await downloads.fetch(
          Uri.parse('$source$manifestName'), p.join(staging, manifestName),
          missingCode: missing, maxBytes: 1024 * 1024);
    }
    final manifest = await readObject(p.join(staging, manifestName));
    checkManifest(manifest, kind, sdk);
    for (final file in hostFiles(manifest, sdk.host)) {
      await downloads.fetch(Uri.parse('$source${file['name']}'),
          p.join(staging, file['name'] as String),
          missingCode: missing, maxBytes: file['size'] as int);
    }
    await validateFiles(staging, manifest, host: sdk.host);
    await writeObject(p.join(staging, 'source.json'), {'url': source});
    if (outdated) {
      // Valid but superseded: nothing to diagnose, so it is not kept.
      final retired = temporaryName('$directory.retired');
      await Directory(directory).renameRetry(retired);
      await Directory(staging).renameRetry(directory);
      await _discard(retired);
    } else {
      if (await Directory(directory).exists()) await quarantine(directory);
      await Directory(staging).renameRetry(directory);
    }
    return manifest;
  }

  static Future<bool> _sameBytes(String a, String b) async {
    final left = await File(a).readAsBytes(),
        right = await File(b).readAsBytes();
    if (left.length != right.length) return false;
    for (var i = 0; i < left.length; i++) {
      if (left[i] != right[i]) return false;
    }
    return true;
  }

  static Future<void> _discard(String path) async {
    try {
      if (await Directory(path).exists()) {
        await Directory(path).deleteRetry(recursive: true);
      }
    } on FileSystemException {
      // A leftover staging directory is never read as a cache.
    }
  }

  /// Moves a flat engine cache (`engine/engine.manifest.json` directly under
  /// the version) into this host's directory, so offline users keep their
  /// validated artifacts. The normal validation then accepts or quarantines it.
  Future<void> _migrateLegacyEngineCache(
      SdkIdentity sdk, String directory) async {
    final legacy = p.dirname(directory);
    if (await Directory(directory).exists() ||
        !await File(p.join(legacy, 'engine.manifest.json')).exists()) {
      return;
    }
    await rejectLinks(legacy);
    final parked = temporaryName(legacy);
    await Directory(legacy).renameRetry(parked);
    await Directory(legacy).create(recursive: true);
    await Directory(parked).renameRetry(directory);
  }

  /// Engine artifacts are cached per host so a cache directory shared between
  /// hosts (WSL2 and Windows, for example) never fights over gen_snapshot.
  String _directory(SdkIdentity sdk, String kind) => kind.startsWith('engine')
      ? p.join(root, 'artifacts', sdk.version, kind, sdk.host.key)
      : p.join(root, 'artifacts', sdk.version, kind);

  String file(SdkIdentity sdk, String kind, String name) =>
      p.join(_directory(sdk, kind), name);
}
