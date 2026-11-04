import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:flutter_patcher/src/cli/core.dart';
import 'package:flutter_patcher/src/cli/baseline/repository.dart';
import 'package:flutter_patcher/src/cli/baseline/store.dart';
import 'package:flutter_patcher/src/cli/publish/pipeline.dart';
import 'package:flutter_patcher/src/cli/patch/package.dart';
import 'package:flutter_patcher/src/cli/cli.dart';
import 'package:flutter_patcher/src/cli/publish/command.dart';
import 'package:flutter_patcher/src/cli/publish/store.dart';
import 'package:flutter_patcher/src/cli/publish/transaction.dart';

import 'baseline_test.dart' as base;

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

/// A signed patch package, as patch android writes it; [target] pins it to
/// one release.
Future<Uint8List> testPatch(
  String dir,
  String fingerprint,
  int seq, {
  Map<String, dynamic>? target,
}) async {
  final work = await Directory(dir).createTemp('patch-');
  final module = p.join(work.path, 'module.bc');
  await File(module).writeAsBytes(List.filled(128, 1));
  final packed = await packPatch(
    kind: 'bytecode',
    code: module,
    work: work.path,
    metadata: {
      'patch_seq': seq,
      'fingerprint': fingerprint,
      'tier': 'lean',
      'target': ?target,
    },
    key: signingKey(base.testSeed),
    commands: Commands(work.path),
  );
  return File(packed['file'] as String).readAsBytes();
}

void main() {
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
      final patch = File(p.join(temp.path, 'patch.fptc'));
      await patch.writeAsBytes(
        await testPatch(
          temp.path,
          fp,
          1,
          target: {
            'flavor': 'default',
            'version_code': '1',
            'abi': 'arm64-v8a',
            'release_manifest_sha256': saved['release']['manifest_sha256'],
          },
        ),
      );
      final priv = File(p.join(temp.path, 'private'));
      await priv.writeAsString(seed);
      final pub = File(p.join(temp.path, 'public'));
      await pub.writeAsString(public);
      final req = File(p.join(temp.path, 'request.json'));
      await writeObject(req.path, {
        'application_id': 'com.example.app',
        'operation': 'a' * 32,
        'store': Directory(p.join(temp.path, 'publication')).uri.toString(),
        'baseline_store': Directory(store.root).uri.toString(),
        'private_key': priv.path,
        'public_key': pub.path,
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
        await runCli(['publish', '--production', '--request', req.path]),
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
          '--yes',
        ]),
        0,
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
      final project = p.join(temp.path, 'project');
      final keys = p.join(project, 'flutter_patcher_keys', 'publisher');
      await Directory(keys).create(recursive: true);
      await File(p.join(keys, 'private-key.base64')).writeAsString(seed);
      await File(p.join(keys, 'public-key.base64')).writeAsString(public);
      await File(p.join(project, 'flutter_patcher.yaml')).writeAsString(
        "store: '${Directory(p.join(temp.path, 'publication')).uri}'\n"
        "baseline_store: '${Directory(store.root).uri}'\n",
      );
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
        'scope': {...fields, 'channel': 'stable', 'abi': 'arm64-v8a'},
      });
      Future<int> withdraw([List<String> extra = const []]) => runCli([
        'publish',
        '--project',
        project,
        '--withdraw',
        ...extra,
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
          seed: seed,
          publicKey: public,
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
