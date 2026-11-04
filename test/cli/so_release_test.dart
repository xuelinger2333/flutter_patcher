import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:flutter_patcher/src/cli/core.dart';
import 'package:flutter_patcher/src/cli/baseline/archive.dart';
import 'package:flutter_patcher/src/cli/baseline/manifest.dart';
import 'package:flutter_patcher/src/cli/baseline/repository.dart';
import 'package:flutter_patcher/src/cli/baseline/split.dart';
import 'package:flutter_patcher/src/cli/build/host_policy.dart';
import 'package:flutter_patcher/src/cli/patch/package.dart';
import 'package:flutter_patcher/src/cli/publish/pipeline.dart';
import 'package:flutter_patcher/src/cli/publish/seal.dart';
import 'package:flutter_patcher/src/cli/keys/bundle.dart';

import 'baseline_test.dart' as base;
import 'release_fixture.dart';
import 'signers.dart';

void main() {
  final f = ReleaseFixture();
  setUp(f.setUp);
  tearDown(f.tearDown);
  final key = base64Encode(List.filled(32, 1));
  HostPolicy policy({Map<String, String> change = const {}}) => HostPolicy({
    'schema': '1',
    'application_id': 'com.example.app',
    'version_code': '42',
    'channel': 'stable',
    'flavor': 'prod',
    'abi': 'arm64-v8a',
    'strategy': 'so',
    'fptc_key': base.testPublicKey,
    'root_key': key,
    'keys': 'one:$key',
    ...change,
  });
  Future<Map<String, dynamic>> saveSo({
    HostPolicy? host,
    Map<String, dynamic> receipt = const {},
  }) async {
    final selected = host ?? policy();
    await File(p.join(f.input, 'host_policy.json'))
        .writeAsString(selected.canonical);
    final m = base.metadata();
    return f.repository.saveSo(
      f.input,
      {
        'application_id': 'com.example.app',
        'public_key': base.testPublicKey,
        'libapp_sha256': await hashFile(p.join(f.input, 'libapp.so')),
        'resources': {'schema': 1, 'files': {}, 'manifest': {}},
        'package_inputs': {},
        'apk_sha256': 'e' * 64,
        'build_host': {'os': 'linux', 'arch': 'x64'},
        'crlf_dart_sources': [],
        ...receipt,
      },
      selected,
      flutterVersion: m['flutter_version'] as String,
      engineCommit: m['engine_commit'] as String,
      buildId: m['build_id'] as String,
    );
  }

  test('an SO host archives one release object and resolves without a compile object', () async {
    final result = await saveSo();
    final m = base.metadata();
    expect(result['strategy'], 'so');
    expect(
      result['fingerprint'],
      soFingerprint(
        m['flutter_version'] as String,
        m['engine_commit'] as String,
        m['build_id'] as String,
        policy().digest,
      ),
    );
    expect(
      (await f.stored()).keys,
      unorderedEquals([
        'release-prod-42-arm64-v8a.tar.gz',
        'apk-${'e' * 64}.json',
      ]),
    );
    final fresh = BaselineRepository(p.join(f.temp.path, 'fresh'), f.store);
    final resolved = await fresh.resolve('prod', '42');
    expect(resolved.strategy, 'so');
    expect(resolved.fingerprint, result['fingerprint']);
    expect(resolved.receipt['public_key'], base.testPublicKey);
    expect((await fresh.verifyRelease('prod', '42'))['strategy'], 'so');
  });

  test(
    'the same SO build is existing; other content needs a new versionCode',
    () async {
      await saveSo();
      expect((await saveSo())['release_status'], 'existing');
      await File(p.join(f.input, 'libapp.so')).writeAsString('other binary');
      await expectLater(saveSo(), fails('BASELINE_RELEASE_CONFLICT'));
    },
  );

  test(
    'publication accepts only SO packages pinned to the SO release',
    () async {
      final fp = (await saveSo())['fingerprint'] as String;
      Map<String, String> fields(String strategy) => {
        'application_id': 'com.example.app',
        'version_code': '42',
        'flavor': 'prod',
        'abi': 'arm64-v8a',
        'fingerprint': fp,
        'strategy': strategy,
      };
      await expectLater(
        resolvePublication(
          f.store,
          fields('bytecode'),
          p.join(f.temp.path, 'b'),
        ),
        fails('PUBLISH_TARGET_MISMATCH'),
      );
      final release = await resolvePublication(
        f.store,
        fields('so'),
        p.join(f.temp.path, 's'),
      );
      final work = (await f.temp.createTemp('seal-')).path;
      final libapp = File(p.join(work, 'libapp.so'))..writeAsBytesSync([1]);
      final patch = await sealPatch(
        await packPatch(
          kind: 'libapp',
          code: libapp.path,
          metadata: {
            'fingerprint': fp,
            'module_id': 123,
            'target': release.target,
          },
        ),
        seq: 1,
        signer: testSigner(base.testSeed, KeyRole.patch),
      );
      checkPatchTarget(patch, 'so', release.identity, release.target);
      expect(
        () => checkPatchTarget(
          patch,
          'bytecode',
          release.identity,
          release.target,
        ),
        throwsA(isA<Failure>()),
      );
    },
  );

  test('policy strategy, key and identity must match the SO release', () async {
    await expectLater(
      saveSo(host: policy(change: {'strategy': 'bytecode'})),
      fails('BUILD_CONFIG_INVALID'),
    );
    await expectLater(
      saveSo(receipt: {'public_key': key}),
      fails('BASELINE_INVALID'),
    );
    await saveSo();
    final dir = await f.temp.createTemp('tampered-');
    final object = p.join(f.storePath, 'release-prod-42-arm64-v8a.tar.gz');
    await BaselineArchive().unpack(
      object,
      p.join(dir.path, 'r'),
      kind: 'release',
    );
    final root = p.join(dir.path, 'r');
    final manifest = await baselineObject(
      p.join(root, 'release.manifest.json'),
    );
    (manifest['identity'] as Map)['fingerprint'] = 'f' * 64;
    await writeObject(p.join(root, 'release.manifest.json'), manifest);
    await expectLater(verifyReleaseObject(root), fails('BASELINE_INVALID'));
  });
}
