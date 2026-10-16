import 'dart:convert';
import 'dart:typed_data';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'host_tools.dart';
import 'package:flutter_patcher_cli/src/core.dart';
import 'package:flutter_patcher_cli/src/crypto/signing.dart';
import 'package:flutter_patcher_cli/src/publish/pipeline.dart';
import 'package:flutter_patcher_cli/src/publish/protocol.dart';
import 'package:flutter_patcher_cli/src/publish/store.dart';
import 'package:flutter_patcher_cli/src/publish/transaction.dart';
import 'baseline_test.dart' as base;
import 'publication_baseline_test.dart' show testPatch;
import 'release_fixture.dart';

void main() {
  final f = ReleaseFixture();
  late FilePublishStore publication;
  late PublicationPipeline pipe;
  setUp(() async {
    await f.setUp();
    publication = FilePublishStore(p.join(f.temp.path, 'publication'));
    pipe = PublicationPipeline(
        PublicationTransaction(publication, 'com.example.app'),
        Commands(f.temp.path),
        f.temp.path);
  });
  tearDown(f.tearDown);

  Future<PublicationRelease> release(String vc, String fp) =>
      resolvePublication(
          f.store,
          {
            'application_id': 'com.example.app',
            'version_code': vc,
            'flavor': 'prod',
            'abi': 'arm64-v8a',
            'fingerprint': fp
          },
          p.join(f.temp.path,
              'publish-$vc-${DateTime.now().microsecondsSinceEpoch}'));
  Map<String, String> fields(PublicationRelease target, Uint8List patch,
      String vc, int seq, String operation) {
    final sha = digest(patch);
    return {
      'schema': '1',
      'key_id': 'release',
      'application_id': 'com.example.app',
      'channel': 'stable',
      'flavor': 'prod',
      'version_code': vc,
      'abi': 'arm64-v8a',
      'fingerprint': target.identity['fingerprint'] as String,
      'strategy': 'bytecode',
      'minPluginVersion': '2.0.0',
      'revision': '$seq',
      'action': 'publish',
      'patch_seq': '$seq',
      'sha256': sha,
      'size': '${patch.length}',
      'url': 'https://example.com/objects/$operation/$sha.fptc'
    };
  }

  Future<Map<String, dynamic>> publish(PublicationRelease target,
          Uint8List patch, String vc, int seq, String operation) =>
      pipe.execute(
          operation: operation,
          fields: fields(target, patch, vc, seq, operation),
          expectedRevision: 0,
          seed: base.testSeed,
          publicKey: base.testPublicKey,
          createdAt: '1',
          baseline: target.identity,
          target: target.target,
          patch: patch,
          commit: true);
  Future<void> editCatalog(void Function(Map<String, dynamic>) change) async {
    final current = (await publication.read('catalog.json'))!;
    final catalog =
        jsonDecode(utf8.decode(current.bytes)) as Map<String, dynamic>;
    change(catalog);
    expect(
        await publication.write('catalog.json', encode(catalog), current.token),
        true);
  }

  Future<Map<String, dynamic>> catalog() async =>
      jsonDecode(utf8.decode((await publication.read('catalog.json'))!.bytes))
          as Map<String, dynamic>;

  /// Releases prod-42 and prod-43, built from the same Dart sources.
  Future<String> sharedFingerprint() async {
    final fp = (await f.save('42'))['fingerprint'] as String;
    await f.nativeChange('43');
    await f.save('43');
    return fp;
  }

  group('publication', () {
    test('a release accepts only patches pinned to it', () async {
      final fp = (await f.save('42'))['fingerprint'] as String;
      final pinned = await release('42', fp);
      final unpinned = await testPatch(f.temp.path, fp, 1);
      await expectLater(publish(pinned, unpinned, '42', 1, 'a' * 32),
          fails('PUBLISH_TARGET_MISMATCH'));
      final other = await testPatch(f.temp.path, fp, 1,
          target: {...pinned.target!, 'version_code': '41'});
      await expectLater(publish(pinned, other, '42', 1, 'b' * 32),
          fails('PUBLISH_TARGET_MISMATCH'));
      final good = await testPatch(f.temp.path, fp, 1, target: pinned.target);
      expect((await publish(pinned, good, '42', 1, 'c' * 32))['status'],
          'published');
    });

    test('a legacy release accepts an unpinned patch, not another release\'s',
        () async {
      final fp = await f.writeLegacy(base.buildMetadata());
      await f.nativeChange('43');
      expect((await f.save('43'))['fingerprint'], fp);
      final legacy = await release('42', fp), next = await release('43', fp);
      expect(legacy.identity.keys, ['receipt', 'baseline', 'fingerprint']);
      final foreign = await testPatch(f.temp.path, fp, 1, target: next.target);
      await expectLater(publish(legacy, foreign, '42', 1, 'a' * 32),
          fails('PUBLISH_TARGET_MISMATCH'));
      final unpinned = await testPatch(f.temp.path, fp, 1);
      expect((await publish(legacy, unpinned, '42', 1, 'b' * 32))['status'],
          'published');
    });

    test('an equivalent legacy sidecar keeps the legacy identity', () async {
      final saved = await f.save('42');
      final fp = await f.writeLegacy(base.buildMetadata());
      final both = await release('42', fp);
      expect(both.identity.keys, ['receipt', 'baseline', 'fingerprint']);
      expect(both.target!['release_manifest_sha256'],
          saved['release']['manifest_sha256']);
    });

    test('releases sharing a fingerprint share one sequence space', () async {
      final fp = await sharedFingerprint();
      final first = await release('42', fp), second = await release('43', fp);
      await publish(
          first,
          await testPatch(f.temp.path, fp, 5, target: first.target),
          '42',
          5,
          'a' * 32);
      await expectLater(
          publish(
              second,
              await testPatch(f.temp.path, fp, 5, target: second.target),
              '43',
              5,
              'b' * 32),
          fails('PUBLISH_SEQUENCE_CONFLICT'));
      expect(
          (await publish(
              second,
              await testPatch(f.temp.path, fp, 6, target: second.target),
              '43',
              6,
              'c' * 32))['status'],
          'published');
    });

    test('a resumed operation violating the sequence rule releases its gate',
        () async {
      final fp = await sharedFingerprint();
      final first = await release('42', fp), second = await release('43', fp);
      await publish(
          first,
          await testPatch(f.temp.path, fp, 5, target: first.target),
          '42',
          5,
          'a' * 32);
      // An earlier CLI reserved the gate for this operation, then stopped.
      final patch = await testPatch(f.temp.path, fp, 5, target: second.target);
      final manifest =
          PublishManifest(fields(second, patch, '43', 5, 'b' * 32));
      final intent = {
        'kind': 'publish',
        'manifest': manifest.envelope(signMessage(
            manifest.signingBytes, base.testSeed, base.testPublicKey)),
        'expected_revision': 0,
        'created_at': '1',
        'pin': false,
        'baseline': second.identity
      };
      await editCatalog((c) => c['pending'] = {
            'operation': 'b' * 32,
            'intent': digest(encode(intent))
          });
      await expectLater(publish(second, patch, '43', 5, 'b' * 32),
          fails('PUBLISH_SEQUENCE_CONFLICT'));
      final after = await catalog();
      expect(after['pending'], isNull);
      expect(after['operations']['b' * 32]['receipt']['status'], 'rejected');
      expect(
          (await publish(
              second,
              await testPatch(f.temp.path, fp, 6, target: second.target),
              '43',
              6,
              'c' * 32))['status'],
          'published');
    });

    test('a malformed catalog record is a rejection, not a crash', () async {
      final fp = await sharedFingerprint();
      final first = await release('42', fp), second = await release('43', fp);
      await publish(
          first,
          await testPatch(f.temp.path, fp, 1, target: first.target),
          '42',
          1,
          'a' * 32);
      await editCatalog(
          (c) => (c['releases'] as Map)['a' * 32]['wire'] = 'not an envelope');
      await expectLater(
          publish(
              second,
              await testPatch(f.temp.path, fp, 2, target: second.target),
              '43',
              2,
              'b' * 32),
          fails('PUBLISH_SEQUENCE_CONFLICT'));
      expect((await catalog())['pending'], isNull);
    });
  }, tags: 'zstd', skip: skipUnless('zstd') ?? false);
}
