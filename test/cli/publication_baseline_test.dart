import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:flutter_patcher/src/cli/core.dart';
import 'package:flutter_patcher/src/cli/baseline/repository.dart';
import 'package:flutter_patcher/src/cli/baseline/store.dart';
import 'package:flutter_patcher/src/cli/publish/pipeline.dart';
import 'package:flutter_patcher/src/cli/publish/seal.dart';
import 'package:flutter_patcher/src/cli/keys/bundle.dart';
import 'package:flutter_patcher/src/cli/patch/package.dart';
import 'package:flutter_patcher/src/cli/cli.dart';
import 'package:flutter_patcher/src/cli/publish/command.dart';
import 'package:flutter_patcher/src/cli/publish/store.dart';
import 'package:flutter_patcher/src/cli/publish/transaction.dart';

import 'baseline_test.dart' as base;
import 'signers.dart';

/// Takes the operation gate, then stops before committing, as a publisher
/// that loses its connection or process does.
class _Interrupted extends PublicationTransaction {
  _Interrupted(super.store, super.application);
  @override
  Future<Map<String, dynamic>> run(
    String operation,
    Map<String, dynamic> intent,
    Future<Map<String, dynamic>> Function(Map<String, dynamic>) action,
  ) => super.run(
    operation,
    intent,
    (_) async => throw Failure('PUBLISH_UPLOAD_FAILED', 'interrupted'),
  );
}

/// A patch draft, as patch android writes it; [target] pins it to one
/// release.
Future<PatchDraft> testDraft(
  String dir,
  String fingerprint,
  int seq, {
  Map<String, dynamic>? target,
}) async {
  final work = await Directory(dir).createTemp('patch-');
  final module = p.join(work.path, 'module.bc');
  await File(module).writeAsBytes(List.filled(128, 1));
  return packPatch(
    kind: 'bytecode',
    code: module,
    metadata: {
      'module_id': seq + 100,
      'fingerprint': fingerprint,
      'tier': 'lean',
      'target': ?target,
    },
  );
}

/// The draft sealed with the test patch key, as publish seals it.
Future<Uint8List> testPatch(
  String dir,
  String fingerprint,
  int seq, {
  Map<String, dynamic>? target,
}) async => sealPatch(
  await testDraft(dir, fingerprint, seq, target: target),
  signer: testSigner(base.testSeed, KeyRole.patch),
  seq: seq,
);
void main() {
  for (final kind in ['bytecode', 'libapp']) {
    test(
      '$kind assigns sequences at publication and resumes without renumbering',
      () async {
        final temp = await Directory.systemTemp.createTemp('draft-sequence-');
        addTearDown(() => temp.delete(recursive: true));
        final code = File(p.join(temp.path, 'code'))
          ..writeAsBytesSync([1, 2, 3]);
        final fp = 'ab' * 32;
        final drafts = [
          for (var i = 0; i < 3; i++)
            await packPatch(
              kind: kind,
              code: code.path,
              metadata: {'fingerprint': fp, 'module_id': 123 + i},
            ),
        ];
        final patchSigner = testSigner(base.testSeed, KeyRole.patch);
        final store = FilePublishStore(p.join(temp.path, 'store'));
        final tx = PublicationTransaction(store, 'com.example.app');
        final pipeline = PublicationPipeline(
          tx,
          Commands(temp.path),
          temp.path,
        );
        Future<Map<String, dynamic>> publish(
          int revision, {
          int? seq,
          bool commit = true,
          PublicationPipeline? via,
        }) => (via ?? pipeline).publishDraft(
          operation: revision.toRadixString(16).padLeft(32, '0'),
          fields: {
            'schema': '1',
            'key_id': 'release',
            'application_id': 'com.example.app',
            'channel': 'stable',
            'flavor': 'default',
            'version_code': '1',
            'abi': 'arm64-v8a',
            'fingerprint': fp,
            'strategy': kind == 'libapp' ? 'so' : 'bytecode',
            'minPluginVersion': '1.0.0',
            'action': 'publish',
            'revision': '$revision',
          },
          expectedRevision: revision - 1,
          signer: testSigner(base.testSeed),
          patchSigner: patchSigner,
          createdAt: '1',
          baseline: {
            'fingerprint': fp,
            'receipt': {
              'application_id': 'com.example.app',
              'version_code': '1',
              'public_key': patchSigner.publicKey,
            },
          },
          draft: drafts[revision - 1],
          sequence: seq,
          commit: commit,
        );
        expect((await publish(1, commit: false))['patch_seq'], 1);
        expect(await store.read('catalog.json'), isNull);
        expect((await publish(1))['patch_seq'], 1);
        expect((await publish(2, seq: 10))['patch_seq'], 10);
        await expectLater(
          publish(3, seq: 9, commit: false),
          throwsA(isA<Failure>()),
        );
        await expectLater(
          publish(
            3,
            via: PublicationPipeline(
              _Interrupted(store, 'com.example.app'),
              Commands(temp.path),
              temp.path,
            ),
          ),
          throwsA(isA<Failure>()),
        );
        expect((await publish(3, commit: false))['patch_seq'], 11);
        final resumed = await publish(3);
        expect(resumed['patch_seq'], 11);
        expect(await publish(3), resumed);
        final bytes = Uint8List.fromList(
          (await store.read(resumed['object'] as String))!.bytes,
        );
        expect(patchManifest(bytes)!['patch_seq'], 11);
        expect(patchManifest(bytes)!['module_id'], 125);
        expect(drafts.last.manifest.containsKey('patch_seq'), false);
      },
    );
  }
  test(
    'publication verifies actual archive identity; cache cannot mask deletion',
    () async {
      final temp = await Directory.systemTemp.createTemp('publish-baseline-');
      addTearDown(() => temp.delete(recursive: true));
      final input = p.join(temp.path, 'input');
      const seed = 'nWGxne/9WmC6hEr0kuwsxERJxWl7MmkZcDusAxyuf2A=';
      const public = '11qYAYKxCrfVS/7TyWQHOg7hcvPapiMlrwIaaPcHURo=';
      await base.fixture(input);
      final metadata = {
        ...base.metadata(),
        'schema': 2,
        'runtime_bootstrap': true,
      };
      final fp =
          (await readObject(
                p.join(input, 'baseline.manifest.json'),
              ))['fingerprint']
              as String;
      await writeObject(p.join(input, 'compiler_interface.json'), {
        'callable': <Object>[],
      });
      await writeObject(p.join(input, 'build_receipt.json'), {
        'runtime_bootstrap': true,
        'module_identity': 1,
        'app_only': true,
        'apk_sha256': 'd' * 64,
        'interface_sha256': await hashFile(
          p.join(input, 'dynamic_interface.yaml'),
        ),
        'libapp_sha256': await hashFile(p.join(input, 'libapp.so')),
        'fingerprint': fp,
        'application_id': 'com.example.app',
        'version_code': '1',
        'public_key': public,
      });
      await Directory(p.join(temp.path, 'store')).create();
      final store = FileBaselineStore(p.join(temp.path, 'store'));
      final saved = await BaselineRepository(
        p.join(temp.path, 'save'),
        store,
      ).save(input, metadata, flavor: 'default', versionCode: '1');
      final fields = {
        'application_id': 'com.example.app',
        'version_code': '1',
        'flavor': 'default',
        'fingerprint': fp,
        'strategy': 'bytecode',
      };
      expect(
        (await publicationBaseline(
          store,
          fields,
          p.join(temp.path, 'fetch'),
        ))['fingerprint'],
        fp,
      );
      await expectLater(
        publicationBaseline(store, {
          ...fields,
          'application_id': 'other.app',
        }, p.join(temp.path, 'wrong')),
        throwsA(isA<Failure>()),
      );
      final patch = Directory(p.join(temp.path, 'draft'))..createSync();
      await (await testDraft(
        temp.path,
        fp,
        1,
        target: {
          'flavor': 'default',
          'version_code': '1',
          'abi': 'arm64-v8a',
          'release_manifest_sha256': saved['release']['manifest_sha256'],
        },
      )).write(patch.path);
      // The project names the keys; a key bundle holds them, as a CI secret
      // would.
      final project = p.join(temp.path, 'project');
      final keys = await writeTestKeys(
        project,
        seed,
        store: Directory(p.join(temp.path, 'publication')).uri.toString(),
        baselineStore: Directory(store.root).uri.toString(),
      );
      final req = File(p.join(temp.path, 'request.json'));
      await writeObject(req.path, {
        'application_id': 'com.example.app',
        'operation': 'a' * 32,
        'store': Directory(p.join(temp.path, 'publication')).uri.toString(),
        'baseline_store': Directory(store.root).uri.toString(),
        'patch': patch.path,
        'expected_revision': 0,
        'created_at': 1,
        'cache_dir': p.join(
          Directory.current.path,
          '.dart_tool',
          'flutter_patcher',
          'publication-test-${DateTime.now().microsecondsSinceEpoch}',
        ),
        'fields': {
          ...fields,
          'schema': '1',
          'key_id': 'release',
          'channel': 'stable',
          'abi': 'arm64-v8a',
          'strategy': 'bytecode',
          'minPluginVersion': '2.0.0',
          'action': 'publish',
          'patch_seq': '1',
          'revision': '1',
        },
      });
      expect(
        await runCli([
          'publish',
          '--production',
          '--request',
          req.path,
          '--project',
          project,
          '--key-file',
          keys,
        ]),
        0,
      );
      expect(
        await runCli([
          'publish',
          '--production',
          '--request',
          req.path,
          '--action',
          'withdraw',
          '--yes',
        ]),
        2,
      );
      expect(
        await File(p.join(temp.path, 'publication', 'catalog.json')).exists(),
        false,
      );
      expect(
        await runCli([
          'publish',
          '--production',
          '--request',
          req.path,
          '--project',
          project,
          '--key-file',
          keys,
          '--yes',
        ]),
        0,
      );
      expect(
        await runCli([
          'publish',
          '--production',
          '--request',
          req.path,
          '--project',
          project,
          '--key-file',
          keys,
          '--yes',
        ]),
        0,
      );
      // The same draft again is already published: no new sequence.
      final again = await publication(
        publishOptions().parse([
          '--production',
          '--request',
          req.path,
          '--project',
          project,
          '--key-file',
          keys,
          '--yes',
        ]),
      );
      expect(again['status'], 'already_published');
      expect(again['patch_seq'], 1);
      // Another project's keys cannot publish this release's patches.
      final draft2 = Directory(p.join(temp.path, 'draft2'))..createSync();
      await (await testDraft(
        temp.path,
        fp,
        2,
        target: {
          'flavor': 'default',
          'version_code': '1',
          'abi': 'arm64-v8a',
          'release_manifest_sha256': saved['release']['manifest_sha256'],
        },
      )).write(draft2.path);
      final req2 = File(p.join(temp.path, 'request2.json'));
      await writeObject(req2.path, {
        ...await readObject(req.path),
        'operation': 'b' * 32,
        'patch': draft2.path,
        'expected_revision': 1,
        'fields': {...(await readObject(req.path))['fields'], 'revision': '2'},
      });
      final stranger = p.join(temp.path, 'stranger');
      final strangerKeys = await writeTestKeys(
        stranger,
        base64Encode(List.filled(32, 9)),
      );
      final before = File(p.join(temp.path, 'publication', 'catalog.json'))
          .readAsStringSync();
      await expectLater(
        publication(
          publishOptions().parse([
            '--production',
            '--request',
            req2.path,
            '--project',
            stranger,
            '--key-file',
            strangerKeys,
            '--yes',
          ]),
        ),
        throwsA(isA<Failure>().having((f) => f.code, 'code', 'KEYS_MISMATCH')),
      );
      expect(
        File(p.join(temp.path, 'publication', 'catalog.json'))
            .readAsStringSync(),
        before,
      );
      // Each run removes its work directory, downloaded baselines included.
      final cacheDir = (await readObject(req.path))['cache_dir'] as String;
      expect(
        Directory(cacheDir)
            .listSync()
            .where((e) => p.basename(e.path).startsWith('publish')),
        isEmpty,
      );
      // Devices read the signed head next to the objects it names.
      final manifests = Directory(p.join(temp.path, 'publication', 'manifests'))
          .listSync();
      expect(manifests, hasLength(1));
      final catalog = jsonDecode(
        File(p.join(temp.path, 'publication', 'catalog.json'))
            .readAsStringSync(),
      ) as Map;
      final head = (catalog['heads'] as Map).values.single;
      expect(
        (manifests.single as File).readAsStringSync(),
        (catalog['releases'] as Map)[head]['wire'],
      );
      // A project withdraws its release's latest patch without a request file.
      final output = p.join(
        project,
        '.dart_tool',
        'flutter_patcher',
        'patches',
        '1',
      );
      await Directory(output).create(recursive: true);
      await writeObject(p.join(output, 'patch.json'), {
        'status': 'patch_created',
        'patch_seq': 1,
        'draft_sha256': 'd' * 64,
        'scope': {...fields, 'channel': 'stable', 'abi': 'arm64-v8a'},
      });
      Future<int> withdraw([List<String> extra = const []]) => runCli([
        'publish',
        '--project',
        project,
        '--withdraw',
        ...extra,
        '--key-file',
        keys,
        '--yes',
      ]);
      expect(await withdraw(['--through', '2']), 2);
      // A withdrawal stops after taking the store's gate. Every new request is
      // refused until the saved one resumes it.
      final interrupted = await projectRequest(
        publishOptions().parse(['--project', project, '--withdraw']),
      );
      final interruptedFields = Map<String, String>.from(
        interrupted['fields'] as Map,
      );
      final work = await Directory(temp.path).createTemp('interrupt-');
      final release = await resolvePublication(
        BaselineStore.open(
          Uri.parse(interrupted['baseline_store'] as String),
          Commands(work.path),
        ),
        interruptedFields,
        work.path,
      );
      await expectLater(
        PublicationPipeline(
          _Interrupted(
            FilePublishStore(p.join(temp.path, 'publication')),
            'com.example.app',
          ),
          Commands(work.path),
          work.path,
        ).execute(
          operation: interrupted['operation'] as String,
          fields: interruptedFields,
          expectedRevision: interrupted['expected_revision'] as int,
          signer: testSigner(seed),
          createdAt: interrupted['created_at'].toString(),
          baseline: release.identity,
          target: release.target,
          commit: true,
        ),
        throwsA(isA<Failure>()),
      );
      expect(await withdraw(), 2);
      await writeObject(pendingRequest(project), interrupted);
      expect(await withdraw(), 0);
      expect(await File(pendingRequest(project)).exists(), false);
      final after = jsonDecode(
        File(p.join(temp.path, 'publication', 'catalog.json'))
            .readAsStringSync(),
      ) as Map;
      final withdrawn =
          (after['releases'] as Map)[(after['heads'] as Map).values.single]
              as Map;
      expect(withdrawn['action'], 'withdraw');
      expect(withdrawn['withdrawn_through'], 1);
      expect(withdrawn['revision'], 2);
      expect((after['heads'] as Map).values.single, interrupted['operation']);
      expect((manifests.single as File).readAsStringSync(), withdrawn['wire']);
      // A saved request the store no longer waits for is discarded.
      await writeObject(pendingRequest(project), interrupted);
      expect(await withdraw(), 2);
      expect(await File(pendingRequest(project)).exists(), false);
      // serve does not bring back a draft published before and withdrawn.
      final withdrawnCatalog = File(
        p.join(temp.path, 'publication', 'catalog.json'),
      ).readAsStringSync();
      final offered = await publication(
        publishOptions().parse([
          '--production',
          '--request',
          req.path,
          '--project',
          project,
          '--key-file',
          keys,
          '--yes',
        ]),
        onlyNew: true,
      );
      expect(offered['status'], 'published_before');
      expect(offered['patch_seq'], 1);
      expect(
        File(p.join(temp.path, 'publication', 'catalog.json'))
            .readAsStringSync(),
        withdrawnCatalog,
      );
      await File(p.join(temp.path, 'store', 'compile-$fp.tar.gz')).delete();
      await expectLater(
        publicationBaseline(store, fields, p.join(temp.path, 'new-fetch')),
        throwsA(isA<Failure>()),
      );
      // The previous successful cache still exists, but a fresh verification cannot use it.
      expect(
        await Directory(
          p.join(temp.path, 'fetch', 'baseline-cache', 'compile', fp),
        ).exists(),
        true,
      );
    },
  );
}
