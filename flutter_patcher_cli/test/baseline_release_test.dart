import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'host_tools.dart';
import 'package:flutter_patcher_cli/src/core.dart';
import 'package:flutter_patcher_cli/src/baseline/archive.dart';
import 'package:flutter_patcher_cli/src/baseline/manifest.dart';
import 'package:flutter_patcher_cli/src/baseline/repository.dart';
import 'package:flutter_patcher_cli/src/baseline/store.dart';
import 'package:flutter_patcher_cli/src/publish/pipeline.dart';
import 'baseline_test.dart' as base;
import 'release_fixture.dart';

void main() {
  final f = ReleaseFixture();
  late Directory temp;
  late String input, storePath;
  late FileBaselineStore store;
  late BaselineRepository repository;
  setUp(() async {
    await f.setUp();
    temp = f.temp;
    input = f.input;
    storePath = f.storePath;
    store = f.store;
    repository = f.repository;
  });
  tearDown(f.tearDown);
  final save = f.save, writeLegacy = f.writeLegacy, policyBuild = f.policyBuild;
  final stored = f.stored;

  group('schema 5 compile and release objects', () {
    test('a rebuild differing only in volatile evidence is the same release',
        () async {
      final first = await save('42');
      expect(first['release_status'], 'created');
      final before = await stored();
      await base.writeReceipt(input, overrides: {
        'apk_sha256': 'e' * 64,
        'build_host': {'os': 'linux', 'arch': 'x64'},
        'crlf_dart_sources': ['package:app/main.dart'],
      });
      final second = await save('42');
      expect(second['release_status'], 'existing');
      expect(second['compile']['status'], 'existing');
      expect(second['attestation'], {
        'object': 'apk-${'e' * 64}.json',
        'status': 'created',
      });
      final after = await stored();
      expect(after.length, before.length + 1);
      for (final name in before.keys) {
        expect(after[name], before[name], reason: name);
      }
      final attestation =
          await readObject(p.join(storePath, 'apk-${'e' * 64}.json'));
      expect(attestation['release_manifest_sha256'],
          first['release']['manifest_sha256']);
      expect(attestation['build_host'], {'os': 'linux', 'arch': 'x64'});
    });

    test('a native-only new versionCode shares one compile object', () async {
      final first = await save('42');
      await File(p.join(input, 'libapp.so')).writeAsString('native change');
      await base.writeReceipt(input, versionCode: '43', overrides: {
        'apk_sha256': 'e' * 64,
        'package_inputs': {
          'app': {
            'native': true,
            'native_files': {'android/x.kt': 'f' * 64}
          }
        },
      });
      final second = await save('43');
      expect(second['fingerprint'], first['fingerprint']);
      expect(second['compile']['status'], 'existing');
      final names = (await stored()).keys;
      expect(names.where((n) => n.startsWith('compile-')).length, 1);
      expect(names.where((n) => n.startsWith('release-')).toSet(), {
        'release-prod-42-arm64-v8a.tar.zst',
        'release-prod-43-arm64-v8a.tar.zst'
      });
    });

    test('a different public key needs a new versionCode', () async {
      await save('42');
      await base.writeReceipt(input,
          overrides: {'public_key': base64Encode(List.filled(32, 2))});
      await expectLater(
          save('42'),
          throwsA(isA<Failure>()
              .having((e) => e.code, 'code', 'BASELINE_RELEASE_CONFLICT')
              .having((e) => e.message, 'message',
                  contains('receipt.public_key'))));
      await base.writeReceipt(input, versionCode: '43', overrides: {
        'public_key': base64Encode(List.filled(32, 2)),
        'apk_sha256': 'e' * 64
      });
      expect((await save('43'))['release_status'], 'created');
    });

    test('compile-file drift under one fingerprint writes no release',
        () async {
      await save('42');
      await writeObject(p.join(input, 'allocate_finalized.json'),
          {'schema': 1, 'classes': <String>[]});
      await base.writeReceipt(input,
          versionCode: '43', overrides: {'apk_sha256': 'e' * 64});
      await expectLater(
          save('43'),
          throwsA(isA<Failure>()
              .having((e) => e.code, 'code', 'BASELINE_CONTENT_CONFLICT')
              .having((e) => e.message, 'message',
                  contains('files.allocate_finalized.json'))));
      expect(
          await File(p.join(storePath, 'release-prod-43-arm64-v8a.tar.zst'))
              .exists(),
          false);
    });

    test('the receipt and host policy must match the archived release',
        () async {
      await expectLater(
          save('41'),
          throwsA(isA<Failure>().having(
              (e) => e.message, 'message', contains('versionCode differs'))));
      final metadata = await policyBuild(change: {'flavor': 'other'});
      await expectLater(
          save('42', metadata: metadata),
          throwsA(isA<Failure>().having((e) => e.message, 'message',
              contains('Host policy differs from the archived release'))));
      final good = await policyBuild();
      final saved = await save('42', metadata: good);
      expect(saved['release_status'], 'created');
      final resolved =
          await BaselineRepository(p.join(temp.path, 'fresh'), store)
              .resolve('prod', '42');
      expect(
          resolved.compile['host_policy_sha256'], good['host_policy_sha256']);
      expect(
          await stored(), isNot(contains('release-prod-41-arm64-v8a.tar.zst')));
    });

    test('a release naming another compile manifest is invalid', () async {
      final saved = await save('42');
      final copy = p.join(temp.path, 'tampered');
      await Directory(copy).create();
      final cached = saved['release']['cache'] as String;
      for (final f in Directory(cached).listSync().whereType<File>()) {
        await f.copy(p.join(copy, p.basename(f.path)));
      }
      final manifest = await readObject(p.join(copy, 'release.manifest.json'));
      (manifest['compile'] as Map)['manifest_sha256'] = 'f' * 64;
      await writeObject(p.join(copy, 'release.manifest.json'), manifest);
      final object = p.join(storePath, 'release-prod-42-arm64-v8a.tar.zst');
      await File(object).delete();
      await BaselineArchive().pack(copy, object);
      await expectLater(
          BaselineRepository(p.join(temp.path, 'fresh'), store)
              .resolve('prod', '42'),
          fails('BASELINE_INVALID'));
    });

    test('resolution works offline from the release and legacy caches',
        () async {
      final saved = await save('42');
      final offline = BaselineRepository(repository.cache, null);
      final resolved = await offline.resolve('prod', '42');
      expect(resolved.format, 'release');
      expect(resolved.compileRoot, saved['compile']['cache']);
      expect(resolved.releaseRoot, saved['release']['cache']);
      expect(resolved.releaseSha, saved['release']['manifest_sha256']);
      await expectLater(
          offline.resolve('prod', '42', expectedFingerprint: 'a' * 64),
          fails('BASELINE_FINGERPRINT_MISMATCH'));
      await expectLater(
          offline.resolve('prod', '7'), fails('BASELINE_NOT_FOUND'));

      final legacyCache = p.join(temp.path, 'legacy-cache');
      final fp = await writeLegacy(base.buildMetadata(), vc: '7');
      final online =
          await BaselineRepository(legacyCache, store).resolve('prod', '7');
      expect(online.format, 'legacy');
      final cachedOnly = BaselineRepository(legacyCache, null);
      await expectLater(
          cachedOnly.resolve('prod', '7'), fails('BASELINE_NOT_FOUND'));
      final fallback =
          await cachedOnly.resolve('prod', '7', expectedFingerprint: fp);
      expect(fallback.format, 'legacy_fingerprint');
      expect(fallback.compileRoot, p.join(legacyCache, fp));
      expect(fallback.target, isNull);
      expect(online.target!['release_manifest_sha256'],
          online.projection!.releaseSha);
    });
  }, tags: 'zstd', skip: skipUnless('zstd') ?? false);

  group('legacy releases', () {
    for (final schema in [2, 3]) {
      test('schema $schema resolves for patch and publish unchanged', () async {
        final metadata =
            schema == 2 ? base.buildMetadata() : await policyBuild();
        final fp = await writeLegacy(metadata);
        final resolved = await repository.resolve('prod', '42');
        expect(resolved.format, 'legacy');
        expect(resolved.fingerprint, fp);
        expect(resolved.compileRoot, p.join(repository.cache, fp));
        expect(resolved.releaseRoot, resolved.compileRoot);
        expect(resolved.receipt['public_key'], base.testPublicKey);
        expect(resolved.target!['version_code'], '42');
        final fields = {
          'application_id': 'com.example.app',
          'version_code': '42',
          'flavor': 'prod',
          'abi': 'arm64-v8a',
          'fingerprint': fp
        };
        final identity = await publicationBaseline(
            store, fields, p.join(temp.path, 'publish'));
        final root = p.join(temp.path, 'publish', 'baseline-cache', fp);
        // The shape is part of pending operations' intent digest.
        expect(
            jsonEncode(identity),
            jsonEncode({
              'receipt':
                  await baselineObject(p.join(root, 'build_receipt.json')),
              'baseline': await verifyBaseline(root),
              'fingerprint': fp
            }));
      });
    }

    test('rebuilding a legacy slot is accepted only for the same build',
        () async {
      await writeLegacy(base.buildMetadata());
      final before = await stored();
      final again = await save('42');
      expect(again['release_status'], 'existing_legacy');
      expect(await stored(), before);
      await File(p.join(input, 'libapp.so')).writeAsString('other binary');
      await base.writeReceipt(input, overrides: {'apk_sha256': 'e' * 64});
      await expectLater(save('42'), fails('BASELINE_RELEASE_CONFLICT'));
      expect(await stored(), before);
    });

    test('a legacy sidecar and a differing release object are ambiguous',
        () async {
      await save('42');
      await File(p.join(input, 'libapp.so')).writeAsString('other binary');
      await base.writeReceipt(input, overrides: {'apk_sha256': 'e' * 64});
      await writeLegacy(base.buildMetadata());
      await expectLater(
          BaselineRepository(p.join(temp.path, 'fresh'), store)
              .resolve('prod', '42'),
          fails('BASELINE_RELEASE_AMBIGUOUS'));
    });
  }, tags: 'zstd', skip: skipUnless('zstd') ?? false);
}
