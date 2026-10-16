import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'host_tools.dart';
import 'package:flutter_patcher_cli/src/core.dart';
import 'package:flutter_patcher_cli/src/baseline/archive.dart';
import 'package:flutter_patcher_cli/src/baseline/repository.dart';
import 'package:flutter_patcher_cli/src/baseline/store.dart';
import 'baseline_test.dart' as base;
import 'release_fixture.dart';

/// Answers a missing object with an access error, as an S3 role without
/// s3:ListBucket does.
class DenyingStore implements BaselineStore {
  final FileBaselineStore inner;
  DenyingStore(this.inner);
  @override
  Future<void> probe() => inner.probe();
  @override
  Future<bool> get(String name, String destination) async {
    if (!await File(p.join(inner.root, name)).exists()) {
      throw Failure('BASELINE_STORE_UNREACHABLE', 'S3 GET failed.');
    }
    return inner.get(name, destination);
  }

  @override
  Future<bool> put(String name, String source) => inner.put(name, source);
}

void main() {
  final f = ReleaseFixture();
  setUp(f.setUp);
  tearDown(f.tearDown);
  Future<bool> quarantined(String dir) async =>
      (await Directory(dir).list().toList())
          .any((e) => e.path.contains('.invalid-'));

  group('shared cache and store behaviour', () {
    test('a shared cache never serves another store\'s release', () async {
      final a = await f.save('42');
      final otherStore = p.join(f.temp.path, 'store-b');
      await Directory(otherStore).create();
      final b =
          BaselineRepository(f.repository.cache, FileBaselineStore(otherStore));
      await f.nativeChange('42');
      final saved = await b.save(f.input, base.buildMetadata(),
          flavor: 'prod', versionCode: '42');
      expect((await b.resolve('prod', '42')).releaseSha,
          saved['release']['manifest_sha256']);
      final again = await f.repository.resolve('prod', '42');
      expect(again.releaseSha, a['release']['manifest_sha256']);
      expect(again.releaseRoot, a['release']['cache']);
      // Offline, the slot entry is trusted as last verified.
      expect(
          (await BaselineRepository(f.repository.cache, null)
                  .resolve('prod', '42'))
              .releaseSha,
          a['release']['manifest_sha256']);
    });

    test('a cached release with a foreign identity is quarantined', () async {
      final saved = await f.save('42');
      final cached = saved['release']['cache'] as String;
      final variant = p.join(p.dirname(cached), 'Other-42-arm64-v8a');
      await Directory(variant).create();
      for (final file in Directory(cached).listSync().whereType<File>()) {
        await file.copy(p.join(variant, p.basename(file.path)));
      }
      final offline = BaselineRepository(f.repository.cache, null);
      await expectLater(
          offline.resolve('Other', '42'), fails('BASELINE_NOT_FOUND'));
      expect(await Directory(variant).exists(), false);
      expect(await quarantined(p.dirname(cached)), true);
    });

    test('a tampered cached release is quarantined and fetched again',
        () async {
      final saved = await f.save('42');
      final cached = saved['release']['cache'] as String;
      await File(p.join(cached, 'libapp.so')).writeAsString('tampered');
      final resolved = await f.repository.resolve('prod', '42');
      expect(resolved.releaseSha, saved['release']['manifest_sha256']);
      expect(await quarantined(p.dirname(cached)), true);
    });

    test('a store that hides missing objects gets an actionable error',
        () async {
      final denying = BaselineRepository(
          p.join(f.temp.path, 'denying'), DenyingStore(f.store));
      await expectLater(
          denying.save(f.input, base.buildMetadata(),
              flavor: 'prod', versionCode: '42'),
          throwsA(isA<Failure>()
              .having((e) => e.code, 'code', 'BASELINE_STORE_UNREACHABLE')
              .having((e) => e.message, 'message',
                  contains('release-prod-42-arm64-v8a'))
              .having((e) => e.message, 'message', contains('NoSuchKey'))));
    });

    test('an unreadable legacy sidecar does not block a valid release',
        () async {
      final saved = await f.save('42');
      await writeObject(p.join(f.storePath, 'release-prod-42-arm64-v8a.json'),
          {'schema': 1, 'fingerprint': 'a' * 64});
      final resolved =
          await BaselineRepository(p.join(f.temp.path, 'fresh'), f.store)
              .resolve('prod', '42');
      expect(resolved.format, 'release');
      expect(resolved.releaseSha, saved['release']['manifest_sha256']);
      expect(resolved.report['warnings'], hasLength(1));
    });

    test('--fingerprint with a schema 5 slot resolves to that release',
        () async {
      final fp = (await f.save('42'))['fingerprint'] as String;
      final resolved =
          await f.repository.resolve('prod', '42', expectedFingerprint: fp);
      expect(resolved.format, 'release');
      expect(resolved.target, isNotNull);
    });

    test('volatile evidence never fails a build', () async {
      await f.save('42');
      await base.writeReceipt(f.input, overrides: {
        'build_host': {'os': 'linux', 'arch': 'x64'}
      });
      final again = await f.save('42');
      expect(again['release_status'], 'existing');
      expect(again['attestation']['status'], 'existing_differs');
    });

    test('archives of one kind cannot be read as another', () async {
      final saved = await f.save('42');
      final compile = p.join(f.storePath, saved['compile']['object'] as String);
      final release = p.join(f.storePath, saved['release']['object'] as String);
      final archive = BaselineArchive();
      for (final (object, kind) in [
        (release, 'compile'), // carries libapp.so
        (compile, 'release'), // carries app.dill
        (compile, 'legacy'),
      ]) {
        await expectLater(
            archive.unpack(object, p.join(f.temp.path, 'as-$kind'), kind: kind),
            fails('BASELINE_INVALID'));
      }
    });
  }, tags: 'zstd', skip: skipUnless('zstd') ?? false);
}
