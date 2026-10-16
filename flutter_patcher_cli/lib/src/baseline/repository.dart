import 'dart:io';
import 'package:path/path.dart' as p;
import '../core.dart';
import '../build/host_policy.dart';
import 'archive.dart';
import 'manifest.dart';
import 'resolve.dart';
import 'split.dart';
import 'store.dart';
export 'resolve.dart' show ResolvedRelease, ReleaseResolution;

String sidecarName(String flavor, String versionCode, String abi) =>
    'release-${releaseSlot(flavor, versionCode, abi)}.json';

/// Legacy release binding; read-only since schema 5.
Map<String, dynamic> sidecar(Map<String, dynamic> m) => {
      'schema': 1,
      'fingerprint': m['fingerprint'],
      'flutter_version': m['flutter_version'],
      'engine_commit': m['engine_commit'],
      'build_id': m['build_id'],
      'libapp_sha256': (m['files'] as Map)['libapp.so']['sha256'],
      if ([2, 3, 4].contains(m['schema'])) 'baseline_schema': m['schema'],
      if ([2, 3, 4].contains(m['schema']))
        'runtime_bootstrap': m['runtime_bootstrap'],
      if (m['schema'] == 3 ||
          (m['schema'] == 4 && m.containsKey('host_policy_sha256')))
        'host_policy_sha256': m['host_policy_sha256'],
      if (m['schema'] == 4)
        'framework_partition_sha256': m['framework_partition_sha256'],
    };

/// Lists release fields that differ, receipt fields included.
List<String> releaseDifferences(Map<String, dynamic> a, Map<String, dynamic> ar,
        Map<String, dynamic> b, Map<String, dynamic> br) =>
    [
      ...manifestDifferences(a, b)
          .where((d) => d != 'files.release_receipt.json'),
      for (final k in {...ar.keys, ...br.keys}.toList()..sort())
        if (canonical(ar[k]) != canonical(br[k])) 'receipt.$k'
    ];

typedef Verify = Future<Map<String, dynamic>> Function(String root,
    {String? sdkRoot});

/// Cache layout under [cache]: legacy baselines at `<fp>/`, schema 5 objects
/// at `compile/<fp>/` and `release/<flavor>-<versionCode>-<abi>/`. The cache
/// is shared by every project and store, so a release entry is trusted only
/// offline; with a store it must equal the stored object.
class BaselineRepository {
  final String cache;
  final BaselineStore? store;
  final BaselineArchive archive;
  BaselineRepository(this.cache, this.store, {BaselineArchive? archive})
      : archive = archive ?? BaselineArchive();
  Future<String> work() async {
    await rejectLinks(cache);
    final path = temporaryName(p.join(cache, '.work'));
    await Directory(path).create(recursive: true);
    return path;
  }

  BaselineStore remote() {
    require(store != null, 'BASELINE_NOT_FOUND',
        'Baseline is not cached and no online store is available.');
    return store!;
  }

  /// Absence decides what is read or written, so a store must report a
  /// missing object as absent rather than as an access error.
  Future<bool> lookup(String name, String destination) async {
    try {
      return await remote().get(name, destination);
    } on Failure catch (e) {
      if (e.code != 'BASELINE_STORE_UNREACHABLE') rethrow;
      throw Failure(e.code,
          'Cannot tell whether $name exists: ${e.message} The store must report a missing object as HTTP 404 or S3 NoSuchKey (an S3 role needs s3:ListBucket).');
    }
  }

  /// [key] is a legacy fingerprint, `compile-<fp>` or `release-<slot>`.
  /// Keys differing only in case share one in-process queue, as their lock
  /// files do on case-insensitive file systems.
  Future<T> locked<T>(String key, Future<T> Function() action) =>
      serialized(p.join(cache, key.toLowerCase()), () async {
        valid(
            RegExp(r'^((compile-)?[0-9a-f]{64}|release-[A-Za-z0-9_-]+-[0-9]+-arm64-v8a)$')
                .hasMatch(key),
            'Invalid requested fingerprint.');
        await rejectLinks(cache);
        await Directory(cache).create(recursive: true);
        final path = p.join(cache, '$key.lock');
        await rejectLinks(path);
        final lock = await File(path).open(mode: FileMode.append);
        await lock.lock(FileLock.blockingExclusive);
        try {
          return await action();
        } finally {
          await lock.unlock();
          await lock.close();
        }
      });

  /// A cache entry is used when it verifies and [accept]s it; with
  /// [authoritative] and a store, only when it also equals the stored object.
  /// Rejected entries are quarantined. An [optional] object that is neither
  /// cached nor stored yields null.
  Future<String?> obtain(
          String key, String target, String object, String kind, Verify verify,
          {String? sdkRoot,
          bool optional = false,
          bool authoritative = false,
          bool Function(Map<String, dynamic>)? accept}) =>
      locked(key, () async {
        await rejectLinks(target);
        Map<String, dynamic>? cached;
        if (await Directory(target).exists()) {
          try {
            final m = await verify(target);
            if (accept == null || accept(m)) cached = m;
          } on Failure {
            // Quarantined below.
          }
          if (cached == null) await quarantine(target);
        }
        if (cached != null && (store == null || !authoritative)) {
          await verify(target, sdkRoot: sdkRoot);
          return target;
        }
        if (optional && store == null) return null;
        final staging = await work(),
            packed = p.join(staging, 'download.tar.zst');
        if (!await lookup(object, packed)) {
          require(optional, 'BASELINE_NOT_FOUND', '$object not found.');
          return null;
        }
        final unpacked = p.join(staging, 'baseline');
        await archive.unpack(packed, unpacked, kind: kind);
        final stored = await verify(unpacked, sdkRoot: sdkRoot);
        valid(accept == null || accept(stored),
            'Stored $object differs from the requested identity.');
        if (cached != null) {
          if (canonical(cached) == canonical(stored)) return target;
          await quarantine(target);
        }
        await Directory(p.dirname(target)).create(recursive: true);
        await Directory(unpacked).renameRetry(target);
        return target;
      });

  /// Legacy (schema 1–4) baseline by fingerprint.
  Future<String> fetch(String fingerprint, {String? sdkRoot}) async =>
      (await obtain(
          fingerprint,
          p.join(cache, fingerprint),
          'baseline-$fingerprint.tar.zst',
          'legacy',
          (r, {sdkRoot}) =>
              verifyBaseline(r, expected: fingerprint, sdkRoot: sdkRoot),
          sdkRoot: sdkRoot))!;

  /// With [manifestSha] (a release's reference) the cached entry must be that
  /// exact compile object.
  Future<String> fetchCompile(String fingerprint,
          {String? sdkRoot, String? manifestSha}) async =>
      (await obtain(
          'compile-$fingerprint',
          p.join(cache, 'compile', fingerprint),
          'compile-$fingerprint.tar.zst',
          'compile',
          (r, {sdkRoot}) =>
              verifyCompile(r, expected: fingerprint, sdkRoot: sdkRoot),
          sdkRoot: sdkRoot,
          accept: (m) =>
              manifestSha == null || manifestDigest(m) == manifestSha))!;

  /// Verified on its own; the caller binds it to its compile object. The
  /// identity check is exact, so a case-variant entry is quarantined.
  Future<String?> fetchReleaseObject(
      String flavor, String versionCode, String abi) {
    final slot = releaseSlot(flavor, versionCode, abi);
    return obtain(
        'release-$slot',
        p.join(cache, 'release', slot),
        'release-$slot.tar.zst',
        'release',
        (r, {sdkRoot}) => verifyReleaseObject(r),
        optional: true,
        authoritative: true,
        accept: (m) =>
            m['flavor'] == flavor &&
            m['version_code'] == versionCode &&
            m['abi'] == abi);
  }

  /// Archives a completed build output as schema 5 compile + release objects.
  /// No compilation or input mutation here.
  Future<Map<String, dynamic>> save(String input, Map<String, dynamic> metadata,
      {required String flavor,
      required String versionCode,
      String abi = 'arm64-v8a'}) async {
    final slot = releaseSlot(flavor, versionCode, abi);
    require(
        [2, 3, 4].contains(metadata['schema']),
        'BASELINE_SCHEMA_UNSUPPORTED',
        'Only build outputs with a build receipt (baseline schema 2-4) can be archived.');
    final staging = await work(), payload = p.join(staging, 'baseline');
    await Directory(payload).create();
    var inputBytes = 0;
    validateMetadata(metadata);
    for (final name in payloadFiles(metadata)) {
      await rejectLinks(p.join(input, name));
      valid(await File(p.join(input, name)).exists(), 'Missing $name');
      inputBytes += await File(p.join(input, name)).length();
      valid(inputBytes <= 1024 * 1024 * 1024,
          'Baseline inputs exceed size limit.');
      await File(p.join(input, name)).copy(p.join(payload, name));
    }
    final manifest = await createManifest(payload, metadata);
    final receipt = await baselineObject(p.join(payload, 'build_receipt.json'));
    valid(receipt['version_code'] == versionCode,
        'Build receipt versionCode differs from the requested release.');
    if (manifest.containsKey('host_policy_sha256')) {
      final policy = HostPolicy.parse(
              await File(p.join(payload, 'host_policy.json')).readAsString())
          .fields;
      valid(
          policy['application_id'] == receipt['application_id'] &&
              policy['version_code'] == versionCode &&
              policy['flavor'] == flavor &&
              policy['abi'] == abi &&
              policy['fptc_key'] == receipt['public_key'],
          'Host policy differs from the archived release.');
    }
    final split = splitBaseline(manifest, receipt,
        flavor: flavor, versionCode: versionCode, abi: abi);
    final fp = manifest['fingerprint'] as String;
    final compileDir = p.join(staging, 'compile'),
        releaseDir = p.join(staging, 'release');
    await writeSplit(payload, split, compileDir, releaseDir);
    final summary = <String, dynamic>{
      'status': 'baseline_archived',
      'baseline_schema': 5,
      'fingerprint': fp,
      'flutter_version': manifest['flutter_version'],
      'engine_commit': manifest['engine_commit'],
      'build_id': manifest['build_id'],
      'libapp_sha256': split.releaseReceipt['libapp_sha256'],
      'runtime_bootstrap': manifest['runtime_bootstrap'],
      'flavor': flavor,
      'version_code': versionCode,
      'abi': abi,
    };
    // A slot archived before schema 5 accepts only the same build again.
    final legacy = await legacySlot(flavor, versionCode, abi);
    if (legacy != null) {
      final old = legacy.projection;
      require(
          old != null && old.releaseSha == split.releaseSha,
          'BASELINE_RELEASE_CONFLICT',
          'release-$slot is already archived (legacy format) with different content'
              '${old == null ? '' : ': ${releaseDifferences(old.release, old.releaseReceipt, split.release, split.releaseReceipt).join(', ')}'}'
              '; bump versionCode.');
      return {
        ...summary,
        'release_status': 'existing_legacy',
        'compile': {
          'object': 'baseline-${legacy.fingerprint}.tar.zst',
          'status': 'existing_legacy',
          'manifest_sha256': split.compileSha,
          'cache': legacy.compileRoot
        },
        'release': {
          'object': sidecarName(flavor, versionCode, abi),
          'status': 'existing_legacy',
          'manifest_sha256': split.releaseSha,
          'cache': legacy.releaseRoot
        },
        'attestation': {'object': null, 'status': 'skipped'},
      };
    }
    final compile = await locked(
        'compile-$fp',
        () => _store('compile-$fp.tar.zst', compileDir, 'compile',
            p.join(cache, 'compile', fp), split, staging));
    final release = await locked(
        'release-$slot',
        () => _store('release-$slot.tar.zst', releaseDir, 'release',
            p.join(cache, 'release', slot), split, staging));
    return {
      ...summary,
      'release_status': release['status'],
      'compile': compile,
      'release': release,
      'attestation': await _attest(receipt, slot, split.releaseSha, staging),
    };
  }

  /// Create-only upload; an existing object must be equivalent.
  Future<Map<String, dynamic>> _store(String object, String dir, String kind,
      String target, SplitBaseline split, String staging) async {
    final manifest = kind == 'compile' ? split.compile : split.release;
    final packed = p.join(staging, object);
    await archive.pack(dir, packed);
    String status;
    if (await remote().put(object, packed)) {
      // Verify what was actually persisted before anything references it.
      final readback = p.join(staging, '$object.readback');
      require(
          await remote().get(object, readback) &&
              await hashFile(readback) == await hashFile(packed),
          'BASELINE_STORE_UNREACHABLE',
          'Uploaded baseline readback failed.');
      status = 'created';
    } else {
      final old = p.join(staging, '$object.existing'),
          expanded = p.join(staging, '$kind-existing');
      require(await remote().get(object, old), 'BASELINE_STORE_UNREACHABLE',
          'Existing object disappeared.');
      await archive.unpack(old, expanded, kind: kind);
      if (kind == 'compile') {
        final prior = await verifyCompile(expanded,
            expected: manifest['fingerprint'] as String);
        require(
            canonical(prior) == canonical(manifest),
            'BASELINE_CONTENT_CONFLICT',
            'Same fingerprint has different content: ${manifestDifferences(prior, manifest).join(', ')}. Existing object retained.');
      } else {
        final prior = await verifyReleaseObject(expanded);
        final priorReceipt =
            await baselineObject(p.join(expanded, 'release_receipt.json'));
        require(
            canonical(prior) == canonical(manifest),
            'BASELINE_RELEASE_CONFLICT',
            '${object.replaceFirst('.tar.zst', '')} is already archived with different content: '
                '${releaseDifferences(prior, priorReceipt, manifest, split.releaseReceipt).join(', ')}; bump versionCode.');
      }
      status = 'existing';
    }
    await _promote(dir, target, manifest, kind);
    return {
      'object': object,
      'status': status,
      'manifest_sha256': manifestDigest(manifest),
      'cache': target,
      'archive_bytes': await File(packed).length(),
      'archive_sha256': await hashFile(packed),
    };
  }

  /// The store is authoritative: a differing cache entry is quarantined.
  Future<void> _promote(String dir, String target,
      Map<String, dynamic> manifest, String kind) async {
    await rejectLinks(target);
    if (await Directory(target).exists()) {
      try {
        final prior = kind == 'compile'
            ? await verifyCompile(target)
            : await verifyReleaseObject(target);
        if (canonical(prior) == canonical(manifest)) return;
      } on Failure {
        // Quarantined below.
      }
      await quarantine(target);
    }
    await Directory(p.dirname(target)).create(recursive: true);
    await Directory(dir).renameRetry(target);
  }

  /// Volatile build evidence, written once per APK and never part of a
  /// baseline identity: no outcome here fails an archived build.
  Future<Map<String, dynamic>> _attest(Map<String, dynamic> receipt,
      String slot, String releaseSha, String staging) async {
    final apk = receipt['apk_sha256'] as String, object = 'apk-$apk.json';
    final value = {
      'schema': 1,
      'apk_sha256': apk,
      'release': 'release-$slot.tar.zst',
      'release_manifest_sha256': releaseSha,
      'build_host': receipt['build_host'],
      'crlf_dart_sources': receipt['crlf_dart_sources'],
    };
    final file = p.join(staging, object),
        readback = p.join(staging, '$object.readback');
    try {
      await writeObject(file, value);
      final created = await remote().put(object, file);
      final same = await remote().get(object, readback) &&
          canonical(await baselineObject(readback)) == canonical(value);
      return {
        'object': object,
        'status': same
            ? (created ? 'created' : 'existing')
            : (created ? 'readback_failed' : 'existing_differs')
      };
    } on Failure catch (e) {
      return {'object': object, 'status': 'failed', 'code': e.code};
    }
  }
}
