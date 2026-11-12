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
    this.root,
    this.version,
    this.engine,
    this.dartVersion,
    this.framework, {
    HostIdentity? host,
  }) : host = host ?? HostIdentity.current();
  String get dart => host.dartBinary(root);
  String get dartAotRuntime => host.dartAotRuntime(root);
  String get flutter => host.flutterLauncher(root);
  Map<String, dynamic> toJson() => {
    'flutter_version': version,
    'engine_commit': engine,
    'dart_version': dartVersion,
    'framework_commit': framework,
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
    (manifest['files'] as List).cast<Map>().where(
      (row) =>
          row['role'] != 'gen_snapshot' ||
          '${row['host_os']}-${row['host_arch']}' == host.key,
    );

/// iOS engine release files. The zip holds the whole Flutter.xcframework:
/// the patched device slice and the stock simulator slice.
const iosFrameworkZip = 'Flutter.xcframework.zip';
const iosFrameworkBinary =
    'Flutter.xcframework/ios-arm64/Flutter.framework/Flutter';

/// gen_snapshot that runs on macos-arm64 and emits iOS arm64 code.
const iosGenSnapshot = 'gen_snapshot_ios-darwin-arm64';

void _checkSource(
  Map<String, dynamic> value,
  String kind,
  SdkIdentity sdk,
  void Function(bool, String) valid,
) {
  valid(
    value['flutter_version'] == sdk.version &&
        value['engine_commit'] == sdk.engine,
    '$kind manifest does not match the selected Flutter SDK.',
  );
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
      'Invalid patch record.',
    );
  }
}

void _checkBuild(
  Map<String, dynamic> value,
  void Function(bool, String) valid,
) {
  valid(
    value['build_id'] is String &&
        RegExp(
          r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
        ).hasMatch(value['build_id']),
    'Invalid engine build_id.',
  );
  valid(_hash(value['depot_tools_rev'], hex40), 'Invalid engine provenance.');
  valid(
    value['built_at'] is String &&
        RegExp(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$')
            .hasMatch(value['built_at']) &&
        DateTime.tryParse(value['built_at']) != null,
    'Invalid build timestamp.',
  );
}

/// The engine API generation this CLI builds hosts with and patches for.
const engineApi = 1;

/// An engine release's API generation and what it offers the plugin, from
/// the engine patches it was built with.
void _checkCapabilities(
  Map<String, dynamic> value,
  void Function(bool, String) valid,
) {
  final names = value['capabilities'];
  valid(
    value['engine_api'] == engineApi &&
        names is List &&
        names.every(
          (name) => name is String && RegExp(r'^[a-z_]+$').hasMatch(name),
        ),
    'Engine API $engineApi with its capabilities is required; '
    'a newer engine needs a newer flutter_patcher.',
  );
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
  _checkCapabilities(value, valid);
  valid(
    verificationPassed(value['verify'], platform: 'ios'),
    'iOS engine verification did not pass.',
  );
  final files = value['files'];
  valid(
    files is List && files.every((row) => row is Map),
    'Invalid file list.',
  );
  final rows = {
    for (final row in (files as List).cast<Map>()) row['role']: row,
  };
  require(
    files.length == 2 &&
        rows.length == 2 &&
        rows.containsKey('framework') &&
        rows.containsKey('gen_snapshot'),
    'ENGINE_ARTIFACT_MISSING',
    'Missing required artifact roles.',
  );
  for (final row in rows.values) {
    valid(
      row['size'] is int && row['size'] > 0 && _hash(row['sha256'], hex64),
      'Invalid file size/hash.',
    );
  }
  final framework = rows['framework']!, snapshot = rows['gen_snapshot']!;
  valid(
    framework['name'] == iosFrameworkZip && snapshot['name'] == iosGenSnapshot,
    'Unexpected artifact filename.',
  );
  valid(
    snapshot['host_os'] == 'macos' && snapshot['host_arch'] == 'arm64',
    'Unsupported gen_snapshot host.',
  );
  final contents = framework['contents'];
  valid(contents is List && contents.length == 1, 'Wrong framework contents.');
  final binary = (contents as List).single;
  valid(
    binary is Map &&
        binary['name'] == iosFrameworkBinary &&
        binary['size'] is int &&
        binary['size'] > 0 &&
        _hash(binary['sha256'], hex64),
    'Invalid inner framework record.',
  );
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
      'Unsafe framework archive entry: ${entry.name}',
    );
  }
  require(
    archive.files.any(
      (entry) => entry.name == 'Flutter.xcframework/Info.plist',
    ),
    'ARTIFACT_INVALID',
    'Framework archive has no xcframework Info.plist.',
  );
  final binaries = archive.files
      .where((entry) => entry.name == record['name'])
      .toList();
  require(
    binaries.length == 1,
    'ARTIFACT_INVALID',
    'Framework archive must contain exactly one device binary.',
  );
  final content = binaries.single.content;
  require(
    content.length == record['size'] &&
        sha256.convert(content).toString() == record['sha256'],
    'ARTIFACT_HASH_MISMATCH',
    'Framework device binary mismatch.',
  );
  require(
    content.length > 8 &&
        content.take(8).join(',') == '207,250,237,254,12,0,0,1',
    'ARTIFACT_INVALID',
    'Framework device binary is not arm64 Mach-O.',
  );
}

void checkManifest(Map<String, dynamic> value, String kind, SdkIdentity sdk) {
  if (kind == 'engine-ios') return _checkIosEngine(value, sdk);
  void valid(bool condition, String message) =>
      require(condition, 'ENGINE_MANIFEST_INVALID', message);
  const hash = _hash;
  // Engine schema 2 lists one gen_snapshot per build host; schema 1
  // releases carry only linux-x64. Tools manifests stay at schema 1.
  final schema = value['schema'];
  valid(
    schema is int && (schema == 1 || (kind == 'engine' && schema == 2)),
    'Unknown $kind manifest schema.',
  );
  _checkSource(value, kind, sdk, valid);
  final files = value['files'];
  final expected = kind == 'engine'
      ? {
          'engine': 'libflutter-arm64_v8a-release.jar',
          'embedding': 'flutter_embedding_release.jar',
        }
      : {'tools': 'flutter_patcher_tools-${sdk.version}.dill'};
  final missing = kind == 'engine'
      ? 'ENGINE_ARTIFACT_MISSING'
      : 'TOOLS_ARTIFACT_MISSING';
  valid(files is List, 'Invalid file list.');
  if (kind == 'tools') {
    require(
      (files as List).length == 1,
      missing,
      'Missing required artifact roles.',
    );
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
        'Unsupported or duplicate gen_snapshot host.',
      );
      final rowHost = HostIdentity(os as String, arch as String);
      snapshotHosts.add(rowHost.key);
      valid(
        rowHost.key == 'linux-x64' || schema == 2,
        'Unsupported gen_snapshot host.',
      );
      valid(
        row['name'] == rowHost.genSnapshotArtifact,
        'Unexpected artifact filename.',
      );
      if (schema == 2) {
        valid(
          row['built_at'] is String &&
              DateTime.tryParse(row['built_at'] as String) != null &&
              hash(row['builder_repo_commit'], hex40) &&
              verificationShape(row['verify']),
          'Invalid gen_snapshot record.',
        );
      }
      if (rowHost.key == sdk.host.key) mine = row;
    } else {
      valid(
        row['role'] is String &&
            expected.containsKey(row['role']) &&
            seen.add(row['role'] as String),
        'Unexpected or duplicate role.',
      );
      valid(
        row['name'] == expected[row['role']],
        'Unexpected artifact filename.',
      );
    }
    valid(
      row['size'] is int && row['size'] > 0 && hash(row['sha256'], hex64),
      'Invalid file size/hash.',
    );
    if (row['role'] == 'engine' || row['role'] == 'embedding') {
      final name = row['role'] == 'engine'
          ? 'arm64_v8a_release'
          : 'flutter_embedding_release';
      valid(
        row['maven'] == 'io.flutter:$name:1.0.0-${value['engine_stamp']}',
        'Wrong Maven coordinate.',
      );
    }
    if (row['role'] == 'engine') {
      final contents = row['contents'];
      valid(
        row['abi'] == 'arm64-v8a' && contents is List && contents.length == 1,
        'Wrong engine ABI/contents.',
      );
      final so = (contents as List).single;
      valid(
        so is Map &&
            so['name'] == 'lib/arm64-v8a/libflutter.so' &&
            so['size'] is int &&
            so['size'] > 0 &&
            hash(so['sha256'], hex64),
        'Invalid inner SO record.',
      );
    }
  }
  if (kind == 'engine') {
    require(
      seen.length == expected.length && snapshotHosts.isNotEmpty,
      missing,
      'Missing required artifact roles.',
    );
    valid(snapshotHosts.contains('linux-x64'), 'Missing primary gen_snapshot.');
    // A release built for other hosts is not corrupt; it simply has nothing
    // for this machine.
    require(
      mine != null,
      missing,
      'Engine release has no gen_snapshot for host ${sdk.host.key} '
      '(release provides ${snapshotHosts.join(', ')}).',
    );
    if (schema == 2) {
      valid(
        verificationPassed(mine!['verify']),
        'gen_snapshot verification for ${sdk.host.key} did not pass.',
      );
    }
    _checkBuild(value, valid);
    _checkCapabilities(value, valid);
    valid(hash(value['engine_stamp'], hex40), 'Invalid engine provenance.');
    valid(
      verificationPassed(value['verify']),
      'Engine verification did not pass.',
    );
  } else {
    valid(
      value['dart_version'] == sdk.dartVersion &&
          hash(value['dart_sdk_commit'], hex40),
      'Tools Dart version mismatch.',
    );
  }
}

Future<void> validateFiles(
  String directory,
  Map<String, dynamic> manifest, {
  HostIdentity? host,
}) async {
  host ??= HostIdentity.current();
  for (final row in hostFiles(manifest, host)) {
    final file = p.join(directory, row['name'] as String);
    await rejectLinks(file);
    require(
      await File(file).exists() &&
          await File(file).length() == row['size'] &&
          await hashFile(file) == row['sha256'],
      'ARTIFACT_HASH_MISMATCH',
      'Size or SHA-256 mismatch: ${row['name']}',
    );
    final bytes = await File(file).readAsBytes();
    if (row['role'] == 'tools') {
      require(
        bytes.length >= 4 && bytes.take(4).join(',') == '144,171,205,239',
        'ARTIFACT_INVALID',
        'Not a kernel dill.',
      );
    } else if (row['role'] == 'gen_snapshot') {
      require(
        host.isNativeExecutable(bytes),
        'ARTIFACT_INVALID',
        'Not a ${host.key} executable.',
      );
    } else if (row['role'] == 'framework') {
      checkFrameworkArchive(
        ZipDecoder().decodeBytes(bytes),
        (row['contents'] as List).single as Map,
      );
    } else {
      final archive = ZipDecoder().decodeBytes(bytes);
      if (row['role'] == 'engine') {
        final record = (row['contents'] as List).single;
        final entries = archive.files
            .where((entry) => entry.name == record['name'])
            .toList();
        require(
          entries.length == 1,
          'ARTIFACT_INVALID',
          'Engine jar must contain exactly one matching SO.',
        );
        final content = entries.single.content;
        require(
          content.length == record['size'] &&
              sha256.convert(content).toString() == record['sha256'],
          'ARTIFACT_HASH_MISMATCH',
          'Engine jar inner SO mismatch.',
        );
        require(
          content.length > 20 &&
              content.take(4).join(',') == '127,69,76,70' &&
              content[18] == 183 &&
              content[19] == 0,
          'ARTIFACT_INVALID',
          'Engine SO is not arm64 ELF.',
        );
      } else {
        require(
          archive.files.any(
            (entry) =>
                entry.name == 'io/flutter/embedding/engine/FlutterJNI.class',
          ),
          'ARTIFACT_INVALID',
          'Embedding jar has no FlutterJNI.',
        );
      }
    }
  }
}

/// One published artifact release: `<kind>-<flutter>-<id>`, where the id is
/// an engine's build_id or the reproducible tools snapshot's digest.
class ArtifactRelease {
  final String kind, tag;

  /// The release manifest's SHA-256, from the index or a baseline.
  final String manifestSha256;
  ArtifactRelease(this.tag, this.manifestSha256)
    : kind = _tagPattern.firstMatch(tag)?.group(1) ?? '' {
    require(
      kind.isNotEmpty && hex64.hasMatch(manifestSha256),
      'ENGINE_MANIFEST_INVALID',
      'Invalid artifact release $tag.',
    );
  }

  static final _tagPattern = RegExp(
    r'^(engine|engine-ios|tools)-(\d+\.\d+\.\d+)-[0-9a-f]{8}$',
  );

  /// [value] as a baseline records it ([toJson]).
  factory ArtifactRelease.fromJson(Object? value) {
    require(
      value is Map &&
          value['tag'] is String &&
          value['manifest_sha256'] is String,
      'ENGINE_MANIFEST_INVALID',
      'Invalid artifact release record.',
    );
    final row = value as Map;
    return ArtifactRelease(
      row['tag'] as String,
      row['manifest_sha256'] as String,
    );
  }

  Map<String, String> toJson() => {
    'tag': tag,
    'manifest_sha256': manifestSha256,
  };

  /// Whether [manifest] is the one this tag names.
  bool names(Map<String, dynamic> manifest) {
    final version = _tagPattern.firstMatch(tag)!.group(2);
    final files = manifest['files'] as List;
    final id = kind == 'tools'
        ? (files.single as Map)['sha256'] as String
        : (manifest['build_id'] as String).replaceAll('-', '');
    return manifest['flutter_version'] == version &&
        tag.endsWith('-${id.substring(0, 8)}');
  }
}

/// Published, immutable artifact releases on this machine. A store serves the
/// releases [select]ed for one run: the index's current ones for a new host,
/// or those a baseline recorded for a patch. A release never changes, so a
/// verified cached copy is used as it is.
class ArtifactStore {
  final String root;

  /// Release downloads (`<base>/<tag>/<file>`) and the release index.
  final Uri base, index;
  final Downloads downloads;
  final Map<String, ArtifactRelease> _selected = {};
  ArtifactStore(this.root, this.base, this.index, this.downloads);

  /// The releases selected so far, by kind.
  Map<String, ArtifactRelease> get selected => Map.unmodifiable(_selected);

  void select(Iterable<ArtifactRelease> releases) {
    for (final release in releases) {
      _selected[release.kind] = release;
    }
  }

  /// Selects the releases [built], which a host of Flutter [version] was
  /// built with: what a patch of it uses. A tools release the index names a
  /// replacement for (`replaced_by`) gives way to it: tools only compile, and
  /// a replacement is published as compatible with what the replaced release
  /// built, so a fix reaches hosts already shipped. An engine is part of the
  /// host and is never replaced.
  Future<void> selectBuilt(
    Iterable<ArtifactRelease> built,
    String version,
  ) async {
    select(built);
    final tools = _selected['tools'];
    if (tools == null) return;
    final Map<String, dynamic> index;
    try {
      index = await _index();
    } on Failure {
      return; // No index, as offline: the release the host recorded.
    }
    final entry = (index['flutter'] as Map)[version];
    final releases = entry is Map ? entry['releases'] as Map : const {};
    var tag = tools.tag;
    final seen = {tag};
    while (true) {
      final current = releases[tag];
      final next = current is Map ? current['replaced_by'] : null;
      if (next is! String) break;
      final row = releases[next];
      require(
        seen.add(next) && row is Map && row['kind'] == 'tools',
        'ENGINE_MANIFEST_INVALID',
        'Invalid artifact index:  is replaced by .',
      );
      tag = next;
    }
    if (tag != tools.tag) {
      select([
        ArtifactRelease(
          tag,
          (releases[tag] as Map)['manifest_sha256'] as String,
        ),
      ]);
    }
  }

  /// Selects the index's current releases for Flutter [version]: what a new
  /// host is built with.
  Future<void> selectCurrent(String version) async {
    require(
      versionPattern.hasMatch(version),
      'ENGINE_ARTIFACT_MISSING',
      'Unsupported Flutter version: $version',
    );
    final flutter = (await _index())['flutter'] as Map;
    final entry = flutter[version];
    require(
      entry is Map,
      'ENGINE_ARTIFACT_MISSING',
      'Flutter $version is not supported. Supported versions: '
          '${(flutter.keys.toList()..sort()).join(', ')}',
    );
    final releases = entry['releases'] as Map;
    select([
      for (final e in (entry['current'] as Map).entries)
        ArtifactRelease(
          e.value as String,
          (releases[e.value] as Map)['manifest_sha256'] as String,
        ),
    ]);
  }

  /// The index, fetched when online; a cached copy serves offline runs and
  /// an unreachable index.
  Future<Map<String, dynamic>> _index() async {
    final key = sha256.convert(utf8.encode(index.toString())).toString();
    final cache = p.join(root, 'index', '$key.json');
    await rejectLinks(cache);
    if (!downloads.offline) {
      final staging = temporaryName(cache);
      try {
        await downloads.fetch(
          index,
          staging,
          missingCode: 'ENGINE_ARTIFACT_MISSING',
          maxBytes: 4 * 1024 * 1024,
        );
        _checkIndex(await readObject(staging));
        await File(staging).renameRetry(cache);
      } catch (error) {
        if (await File(staging).exists()) await File(staging).delete();
        if (!await File(cache).exists()) rethrow;
        stderr.writeln(
          'WARNING: ARTIFACT_CHECK_SKIPPED: using the cached '
          'artifact index; cannot read $index ($error)',
        );
      }
    }
    require(
      await File(cache).exists(),
      'ENGINE_ARTIFACT_MISSING',
      'No artifact index is cached for offline use; run once online.',
    );
    final value = await readObject(cache);
    _checkIndex(value);
    return value;
  }

  /// Every version's current release of a kind is a listed release of it.
  static void _checkIndex(Map<String, dynamic> value) {
    bool version(MapEntry entry) {
      final row = entry.value;
      if (row is! Map || !versionPattern.hasMatch('${entry.key}')) return false;
      final current = row['current'], releases = row['releases'];
      return current is Map &&
          releases is Map &&
          current.entries.every((e) {
            final release = releases[e.value];
            return release is Map && release['kind'] == e.key;
          });
    }

    final flutter = value['flutter'];
    require(
      value['schema'] == 1 && flutter is Map && flutter.entries.every(version),
      'ENGINE_MANIFEST_INVALID',
      'Invalid artifact index.',
    );
  }

  /// The selected [kind] release, downloaded or reused, checked against
  /// [sdk] and the digest its selection recorded.
  Future<Map<String, dynamic>> obtain(String kind, SdkIdentity sdk) async {
    final release = _selected[kind];
    require(
      release != null,
      kind == 'tools' ? 'TOOLS_ARTIFACT_MISSING' : 'ENGINE_ARTIFACT_MISSING',
      'Flutter ${sdk.version} has no published $kind release.',
    );
    final directory = _directory(release!, sdk);
    final manifestName = '$kind.manifest.json';
    await rejectLinks(directory);
    Future<Map<String, dynamic>> verified(String root) async {
      final file = p.join(root, manifestName);
      final manifest = await readObject(file);
      require(
        await hashFile(file) == release.manifestSha256 &&
            release.names(manifest),
        'ARTIFACT_HASH_MISMATCH',
        '${release.tag}: manifest differs from its record.',
      );
      checkManifest(manifest, kind, sdk);
      await validateFiles(root, manifest, host: sdk.host);
      return manifest;
    }

    if (await Directory(directory).exists()) {
      try {
        return await verified(directory);
      } catch (_) {
        if (downloads.offline) rethrow;
        await quarantine(directory);
      }
    }
    final source =
        '${base.toString().replaceAll(RegExp(r'/+$'), '')}/${release.tag}/';
    final missing = kind == 'tools'
        ? 'TOOLS_ARTIFACT_MISSING'
        : 'ENGINE_ARTIFACT_MISSING';
    final staging = temporaryName(directory);
    await downloads.fetch(
      Uri.parse('$source$manifestName'),
      p.join(staging, manifestName),
      missingCode: missing,
      maxBytes: 1024 * 1024,
    );
    final listed = await readObject(p.join(staging, manifestName));
    checkManifest(listed, kind, sdk);
    for (final file in hostFiles(listed, sdk.host)) {
      await downloads.fetch(
        Uri.parse('$source${file['name']}'),
        p.join(staging, file['name'] as String),
        missingCode: missing,
        maxBytes: file['size'] as int,
      );
    }
    final manifest = await verified(staging);
    await Directory(staging).renameRetry(directory);
    return manifest;
  }

  /// Engine releases are cached per host so a cache directory shared between
  /// hosts (WSL2 and Windows, for example) never fights over gen_snapshot.
  String _directory(ArtifactRelease release, SdkIdentity sdk) =>
      release.kind == 'tools'
      ? p.join(root, 'artifacts', release.tag)
      : p.join(root, 'artifacts', release.tag, sdk.host.key);

  String file(SdkIdentity sdk, String kind, String name) {
    final release = _selected[kind];
    require(
      release != null,
      'ENGINE_ARTIFACT_MISSING',
      'No $kind release selected.',
    );
    return p.join(_directory(release!, sdk), name);
  }
}
