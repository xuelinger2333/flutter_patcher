import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import '../core.dart';
import '../build/host_policy.dart';
import 'manifest.dart';

/// Schema 5 stores a baseline as two objects. The compile object holds what
/// the fingerprint determines and patch compilation reads; it is shared by
/// every release built from the same Dart sources. The release object holds
/// what one APK (flavor + versionCode + ABI) adds, and references its compile
/// object by fingerprint and manifest digest.
const compileFiles = <String>[
  'app.dill',
  'dynamic_interface.yaml',
  'interface_detailed.json',
  'compiler_interface.json',
  'allocate_finalized.json',
  'source_hashes.json',
];
const releaseFiles = <String>['libapp.so', 'package_config.json'];

/// Build receipt fields owned by the release object.
const releaseReceiptKeys = {
  'application_id',
  'version_code',
  'public_key',
  'libapp_sha256',
  'resources',
  'package_inputs',
};

/// Differ between rebuilds of identical inputs (APK signing blocks, host OS),
/// so they never take part in an identity comparison.
const volatileReceiptKeys = {'apk_sha256', 'build_host', 'crlf_dart_sources'};

List<String> compilePayload(Map<String, dynamic> m) => [
      ...compileFiles,
      if (m.containsKey('host_policy_sha256')) 'host_policy.json',
      if (m.containsKey('framework_partition_sha256'))
        'framework_partition.json',
      'compile_receipt.json',
    ];
const releasePayload = [...releaseFiles, 'release_receipt.json'];

/// Archive entries per object kind; a compile archive cannot carry libapp.so
/// and a release archive cannot carry app.dill.
final archiveEntries = <String, List<String>>{
  'compile': [
    ...compileFiles,
    'host_policy.json',
    'framework_partition.json',
    'compile_receipt.json',
    'compile.manifest.json'
  ]..sort(),
  'release': [...releasePayload, 'release.manifest.json']..sort(),
};
final requiredEntries = <String, List<String>>{
  'compile': [...compileFiles, 'compile_receipt.json', 'compile.manifest.json'],
  'release': [...releasePayload, 'release.manifest.json'],
};

/// `<flavor>-<versionCode>-<abi>`: the release slot shared by v5 objects,
/// legacy sidecars and the release cache directory.
String releaseSlot(String flavor, String versionCode, String abi) {
  require(
      RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(flavor) &&
          RegExp(r'^[0-9]+$').hasMatch(versionCode) &&
          abi == 'arm64-v8a',
      'CONFIG_INVALID',
      'Explicit flavor (use default if absent), numeric versionCode and arm64-v8a required.');
  return '$flavor-$versionCode-$abi';
}

String manifestDigest(Map<String, dynamic> manifest) =>
    sha256.convert(utf8.encode(canonical(manifest))).toString();

/// Same bytes as writeObject, so a receipt can be hashed before it is written.
List<int> encodeObject(Map<String, dynamic> value) =>
    utf8.encode('${const JsonEncoder.withIndent('  ').convert(value)}\n');

Map<String, dynamic> releaseTarget(Map<String, dynamic> release) => {
      'flavor': release['flavor'],
      'version_code': release['version_code'],
      'abi': release['abi'],
      'release_manifest_sha256': manifestDigest(release),
    };

class SplitBaseline {
  final Map<String, dynamic> compile, release, compileReceipt, releaseReceipt;
  SplitBaseline(
      this.compile, this.release, this.compileReceipt, this.releaseReceipt);
  String get compileSha => manifestDigest(compile);
  String get releaseSha => manifestDigest(release);
}

Map<String, dynamic> _entry(List<int> bytes) =>
    {'sha256': sha256.convert(bytes).toString(), 'size': bytes.length};

Map<String, dynamic> compileReference(Map<String, dynamic> compile) => {
      'fingerprint': compile['fingerprint'],
      'manifest_sha256': manifestDigest(compile),
      'flutter_version': compile['flutter_version'],
      'engine_commit': compile['engine_commit'],
      'runtime_bootstrap': compile['runtime_bootstrap'],
    };

/// Projects a verified schema 2–4 baseline manifest and its build receipt onto
/// the two schema 5 objects. Used both to archive a build and to compare a
/// legacy release with a new build of the same slot.
SplitBaseline splitBaseline(
    Map<String, dynamic> legacy, Map<String, dynamic> receipt,
    {required String flavor,
    required String versionCode,
    required String abi}) {
  valid([2, 3, 4].contains(legacy['schema']),
      'Only baselines with a build receipt (schema 2–4) can be split.');
  releaseSlot(flavor, versionCode, abi);
  final files = legacy['files'] as Map;
  final compileReceipt = <String, dynamic>{
    for (final e in receipt.entries)
      if (!releaseReceiptKeys.contains(e.key) &&
          !volatileReceiptKeys.contains(e.key))
        e.key: e.value
  };
  final compile = <String, dynamic>{
    'schema': 5,
    'kind': 'compile',
    'fingerprint': legacy['fingerprint'],
    'flutter_version': legacy['flutter_version'],
    'engine_commit': legacy['engine_commit'],
    'platform': legacy['platform'],
    'runtime_bootstrap': legacy['runtime_bootstrap'],
    if (legacy.containsKey('host_policy_sha256'))
      'host_policy_sha256': legacy['host_policy_sha256'],
    if (legacy.containsKey('framework_partition_sha256'))
      'framework_partition_sha256': legacy['framework_partition_sha256'],
  };
  compile['files'] = {
    for (final name in compilePayload(compile))
      name: name == 'compile_receipt.json'
          ? _entry(encodeObject(compileReceipt))
          : files[name]
  };
  final releaseReceipt = <String, dynamic>{
    'schema': 1,
    'flavor': flavor,
    'version_code': versionCode,
    'abi': abi,
    'application_id': receipt['application_id'],
    'public_key': receipt['public_key'],
    'libapp_sha256': files['libapp.so']['sha256'],
    'build_id': legacy['build_id'],
    'resources': receipt['resources'],
    'package_inputs': receipt['package_inputs'],
  };
  final release = <String, dynamic>{
    'schema': 5,
    'kind': 'release',
    'flavor': flavor,
    'version_code': versionCode,
    'abi': abi,
    'application_id': receipt['application_id'],
    'build_id': legacy['build_id'],
    'compile': compileReference(compile),
    'files': {
      'libapp.so': files['libapp.so'],
      'package_config.json': files['package_config.json'],
      'release_receipt.json': _entry(encodeObject(releaseReceipt)),
    },
  };
  return SplitBaseline(compile, release, compileReceipt, releaseReceipt);
}

/// Materializes [split] from the flat build output [flat].
Future<void> writeSplit(String flat, SplitBaseline split, String compileDir,
    String releaseDir) async {
  for (final (dir, names, receipt, manifest) in [
    (
      compileDir,
      compilePayload(split.compile),
      split.compileReceipt,
      'compile'
    ),
    (releaseDir, releasePayload, split.releaseReceipt, 'release'),
  ]) {
    await Directory(dir).create(recursive: true);
    for (final name in names) {
      if (name.endsWith('_receipt.json')) {
        await File(p.join(dir, name)).writeAsBytes(encodeObject(receipt));
      } else {
        await File(p.join(flat, name)).copy(p.join(dir, name));
      }
    }
    await writeObject(p.join(dir, '$manifest.manifest.json'),
        manifest == 'compile' ? split.compile : split.release);
  }
}

Future<Map<String, dynamic>> verifyCompile(String root,
    {String? expected, String? sdkRoot}) async {
  await rejectLinks(root);
  final m = await baselineObject(p.join(root, 'compile.manifest.json'));
  valid(m['schema'] == 5 && m['kind'] == 'compile', 'Not a compile object.');
  validateSdkIdentity(m);
  final policyHash = m['host_policy_sha256'] as String?,
      partitionHash = m['framework_partition_sha256'] as String?;
  valid(
      m['runtime_bootstrap'] is bool &&
          (policyHash == null || baselineHash.hasMatch(policyHash)) &&
          (partitionHash == null || baselineHash.hasMatch(partitionHash)) &&
          ((policyHash == null && partitionHash == null) ||
              m['runtime_bootstrap'] == true),
      'Invalid compile object identity.');
  final files = await hashPayload(root, compilePayload(m));
  final interfaceHash = files['dynamic_interface.yaml']['sha256'] as String;
  await validateCompileFiles(root,
      interfaceHash: interfaceHash, partitionHash: partitionHash);
  if (policyHash != null) {
    final policy = HostPolicy.parse(
        await File(p.join(root, 'host_policy.json')).readAsString());
    valid(policy.digest == policyHash, 'Host policy identity differs.');
  }
  final id = fingerprint(
      files['app.dill']['sha256'] as String,
      m['engine_commit'] as String,
      interfaceHash,
      m['flutter_version'] as String,
      hostPolicyHash: policyHash,
      frameworkPartitionHash: partitionHash);
  final receipt = await baselineObject(p.join(root, 'compile_receipt.json'));
  valid(
      receipt['fingerprint'] == id &&
          receipt['interface_sha256'] == interfaceHash &&
          receipt['runtime_bootstrap'] == m['runtime_bootstrap'] &&
          receipt['app_only'] == true &&
          receipt['host_policy_sha256'] == policyHash &&
          receipt['framework_partition_sha256'] == partitionHash &&
          !receipt.keys.any((k) =>
              releaseReceiptKeys.contains(k) ||
              volatileReceiptKeys.contains(k)),
      'Compile receipt binding differs.');
  final computed = {
    'schema': 5,
    'kind': 'compile',
    'fingerprint': id,
    'flutter_version': m['flutter_version'],
    'engine_commit': m['engine_commit'],
    'platform': m['platform'],
    'runtime_bootstrap': m['runtime_bootstrap'],
    if (policyHash != null) 'host_policy_sha256': policyHash,
    if (partitionHash != null) 'framework_partition_sha256': partitionHash,
    'files': files,
  };
  valid(canonical(m) == canonical(computed),
      'Compile manifest/files do not agree.');
  require(expected == null || id == expected, 'BASELINE_FINGERPRINT_MISMATCH',
      'Requested fingerprint differs from baseline.');
  if (sdkRoot != null) await verifyPlatform(computed, sdkRoot);
  return computed;
}

/// Verifies a release object on its own; with [compile] also its reference to
/// that compile object, and with [compileRoot] the host policy binding.
Future<Map<String, dynamic>> verifyReleaseObject(String root,
    {Map<String, dynamic>? compile, String? compileRoot}) async {
  await rejectLinks(root);
  final m = await baselineObject(p.join(root, 'release.manifest.json'));
  valid(m['schema'] == 5 && m['kind'] == 'release', 'Not a release object.');
  releaseSlot('${m['flavor']}', '${m['version_code']}', '${m['abi']}');
  final ref = m['compile'];
  valid(
      m['application_id'] is String &&
          buildIdPattern.hasMatch('${m['build_id']}') &&
          ref is Map &&
          baselineHash.hasMatch('${ref['fingerprint']}') &&
          baselineHash.hasMatch('${ref['manifest_sha256']}') &&
          ref['runtime_bootstrap'] is bool,
      'Invalid release object identity.');
  validateSdkRelease(Map<String, dynamic>.from(ref as Map));
  final files = await hashPayload(root, releasePayload);
  await validatePackages(root);
  final receipt = await baselineObject(p.join(root, 'release_receipt.json'));
  valid(
      receipt.length == 10 &&
          receipt.keys.toSet().containsAll(
              {...releaseReceiptKeys, 'schema', 'flavor', 'abi', 'build_id'}) &&
          receipt['schema'] == 1 &&
          [
            for (final k in ['flavor', 'version_code', 'abi', 'application_id'])
              receipt[k] == m[k]
          ].every((v) => v) &&
          receipt['build_id'] == m['build_id'] &&
          receipt['libapp_sha256'] == files['libapp.so']['sha256'] &&
          (receipt['public_key'] == null || receipt['public_key'] is String),
      'Release receipt binding differs.');
  final computed = {
    for (final k in [
      'schema',
      'kind',
      'flavor',
      'version_code',
      'abi',
      'application_id',
      'build_id',
      'compile'
    ])
      k: m[k],
    'files': files,
  };
  valid(canonical(m) == canonical(computed),
      'Release manifest/files do not agree.');
  if (compile != null) {
    valid(canonical(ref) == canonical(compileReference(compile)),
        'Release references a different compile object.');
  }
  if (compile != null &&
      compileRoot != null &&
      compile.containsKey('host_policy_sha256')) {
    final policy = HostPolicy.parse(
            await File(p.join(compileRoot, 'host_policy.json')).readAsString())
        .fields;
    valid(
        policy['application_id'] == m['application_id'] &&
            policy['version_code'] == m['version_code'] &&
            policy['flavor'] == m['flavor'] &&
            policy['abi'] == m['abi'] &&
            policy['fptc_key'] == receipt['public_key'],
        'Host policy differs from the release.');
  }
  return computed;
}

/// Verifies an extracted baseline directory of any kind; `kind` is null for a
/// legacy (schema 1–4) baseline.
Future<Map<String, dynamic>> verifyBaselineDir(String root,
    {String? expected, String? sdkRoot}) async {
  await rejectLinks(root);
  final kinds = [
    for (final kind in ['baseline', 'compile', 'release'])
      if (await File(p.join(root, '$kind.manifest.json')).exists()) kind
  ];
  valid(kinds.length == 1, 'Expected exactly one baseline manifest.');
  switch (kinds.single) {
    case 'compile':
      return verifyCompile(root, expected: expected, sdkRoot: sdkRoot);
    case 'release':
      final m = await verifyReleaseObject(root);
      require(
          expected == null || m['compile']['fingerprint'] == expected,
          'BASELINE_FINGERPRINT_MISMATCH',
          'Requested fingerprint differs from baseline.');
      return m;
    default:
      return verifyBaseline(root, expected: expected, sdkRoot: sdkRoot);
  }
}

/// Payload names of a verified directory, manifest included.
Future<List<String>> verifiedEntries(String root) async {
  final m = await verifyBaselineDir(root);
  return switch (m['kind']) {
    'compile' => [...compilePayload(m), 'compile.manifest.json'],
    'release' => [...releasePayload, 'release.manifest.json'],
    _ => [...payloadFiles(m), 'baseline.manifest.json'],
  }
    ..sort();
}
