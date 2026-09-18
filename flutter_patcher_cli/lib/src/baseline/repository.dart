import 'dart:io';
import 'package:path/path.dart' as p;
import '../core.dart';
import 'archive.dart';
import 'manifest.dart';
import 'store.dart';

String sidecarName(String flavor, String versionCode, String abi) {
  require(
      RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(flavor) &&
          RegExp(r'^[0-9]+$').hasMatch(versionCode) &&
          abi == 'arm64-v8a',
      'CONFIG_INVALID',
      'Explicit flavor (use default if absent), numeric versionCode and arm64-v8a required.');
  return 'release-$flavor-$versionCode-$abi.json';
}

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

  Future<T> locked<T>(String fingerprint, Future<T> Function() action) =>
      serialized(p.join(cache, fingerprint), () async {
        valid(baselineHash.hasMatch(fingerprint),
            'Invalid requested fingerprint.');
        await rejectLinks(cache);
        await Directory(cache).create(recursive: true);
        final path = p.join(cache, '$fingerprint.lock');
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

  Future<String> fetch(String fingerprint, {String? sdkRoot}) =>
      locked(fingerprint, () async {
        final target = p.join(cache, fingerprint);
        await rejectLinks(target);
        if (await Directory(target).exists()) {
          var intact = false;
          try {
            await verifyBaseline(target, expected: fingerprint);
            intact = true;
          } on Failure {
            await quarantine(target);
          }
          if (intact) {
            await verifyBaseline(target,
                expected: fingerprint, sdkRoot: sdkRoot);
            return target;
          }
        }
        final staging = await work(),
            packed = p.join(staging, 'download.tar.zst');
        require(await remote().get('baseline-$fingerprint.tar.zst', packed),
            'BASELINE_NOT_FOUND', 'Baseline object not found.');
        final unpacked = p.join(staging, 'baseline');
        await archive.unpack(packed, unpacked);
        await verifyBaseline(unpacked, expected: fingerprint, sdkRoot: sdkRoot);
        await Directory(unpacked).rename(target);
        return target;
      });

  /// WP-5 passes its completed output. No compilation or input mutation here.
  Future<Map<String, dynamic>> save(String input, Map<String, dynamic> metadata,
      {required String flavor,
      required String versionCode,
      String abi = 'arm64-v8a'}) async {
    final release = sidecarName(flavor, versionCode, abi);
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
    await writeObject(p.join(payload, 'baseline.manifest.json'), manifest);
    final fingerprint = manifest['fingerprint'] as String;
    return locked(fingerprint, () async {
      final packed = p.join(staging, 'baseline-$fingerprint.tar.zst');
      await archive.pack(payload, packed);
      final name = p.basename(packed);
      if (!await remote().put(name, packed)) {
        final old = p.join(staging, 'existing.tar.zst'),
            expanded = p.join(staging, 'existing');
        require(await remote().get(name, old), 'BASELINE_STORE_UNREACHABLE',
            'Existing object disappeared.');
        await archive.unpack(old, expanded);
        final prior = await verifyBaseline(expanded, expected: fingerprint);
        require(
            canonical(prior) == canonical(manifest),
            'BASELINE_CONTENT_CONFLICT',
            'Same fingerprint has different content: ${manifestDifferences(prior, manifest).join(', ')}. Existing object retained.');
      } else {
        // Verify what was actually persisted, before committing the release sidecar.
        final readback = p.join(staging, 'readback.tar.zst');
        require(
            await remote().get(name, readback) &&
                await hashFile(readback) == await hashFile(packed),
            'BASELINE_STORE_UNREACHABLE',
            'Uploaded baseline readback failed.');
      }
      final link = sidecar(manifest), sideFile = p.join(staging, release);
      await writeObject(sideFile, link);
      if (!await remote().put(release, sideFile)) {
        final old = p.join(staging, 'existing-sidecar.json');
        require(
            await remote().get(release, old) &&
                canonical(await baselineObject(old)) == canonical(link),
            'BASELINE_CONTENT_CONFLICT',
            'Release sidecar already binds different content.');
      }
      final sideReadback = p.join(staging, 'sidecar-readback.json');
      require(
          await remote().get(release, sideReadback) &&
              canonical(await baselineObject(sideReadback)) == canonical(link),
          'BASELINE_STORE_UNREACHABLE',
          'Release sidecar readback failed.');
      final target = p.join(cache, fingerprint);
      await rejectLinks(target);
      if (await Directory(target).exists()) {
        try {
          final prior = await verifyBaseline(target, expected: fingerprint);
          require(canonical(prior) == canonical(manifest),
              'BASELINE_CONTENT_CONFLICT', 'Cache contains different content.');
        } on Failure catch (e) {
          if (e.code == 'BASELINE_CONTENT_CONFLICT') rethrow;
          await quarantine(target);
        }
      }
      if (!await Directory(target).exists()) {
        await Directory(payload).rename(target);
      }
      return {
        'status': 'baseline_archived',
        ...link,
        'sidecar': release,
        'cache': target,
        'archive_bytes': await File(packed).length(),
        'archive_sha256': await hashFile(packed)
      };
    });
  }

  Future<Map<String, dynamic>> verifyRelease(String flavor, String versionCode,
      {String abi = 'arm64-v8a', String? sdkRoot}) async {
    final name = sidecarName(flavor, versionCode, abi);
    final staging = await work(), file = p.join(staging, name);
    require(await remote().get(name, file), 'BASELINE_NOT_FOUND',
        'Release sidecar is missing.');
    final link = await baselineObject(file);
    valid(baselineHash.hasMatch('${link['fingerprint']}'),
        'Invalid sidecar fingerprint.');
    final root = await fetch(link['fingerprint'] as String, sdkRoot: sdkRoot);
    final manifest = await verifyBaseline(root,
        expected: link['fingerprint'] as String, sdkRoot: sdkRoot);
    require(manifest['runtime_bootstrap'] != false, 'BASELINE_NOT_RELEASE',
        'Pipeline validation baseline has no runtime bootstrap and is not a release.');
    valid(canonical(link) == canonical(sidecar(manifest)),
        'Release sidecar binding mismatch.');
    return link;
  }
}
