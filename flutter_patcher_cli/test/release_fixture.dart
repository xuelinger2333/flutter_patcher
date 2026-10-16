import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:flutter_patcher_cli/src/core.dart';
import 'package:flutter_patcher_cli/src/baseline/archive.dart';
import 'package:flutter_patcher_cli/src/baseline/manifest.dart';
import 'package:flutter_patcher_cli/src/baseline/repository.dart';
import 'package:flutter_patcher_cli/src/baseline/store.dart';
import 'package:flutter_patcher_cli/src/build/host_policy.dart';
import 'baseline_test.dart' as base;

Matcher fails(String code) =>
    throwsA(isA<Failure>().having((e) => e.code, 'code', code));

/// A build output, a file store and a cache, as the release tests share them.
class ReleaseFixture {
  late Directory temp;
  late String input, storePath;
  late FileBaselineStore store;
  late BaselineRepository repository;

  Future<void> setUp() async {
    temp = await Directory.systemTemp.createTemp('baseline-release-test-');
    input = p.join(temp.path, 'input');
    await base.buildFixture(input);
    storePath = p.join(temp.path, 'store');
    await Directory(storePath).create();
    store = FileBaselineStore(storePath);
    repository = BaselineRepository(p.join(temp.path, 'cache'), store);
  }

  Future<void> tearDown() => temp.delete(recursive: true);

  Future<Map<String, dynamic>> save(String vc,
          {String flavor = 'prod', Map<String, dynamic>? metadata}) =>
      repository.save(input, metadata ?? base.buildMetadata(),
          flavor: flavor, versionCode: vc);

  Future<Map<String, String>> stored() async => {
        for (final f in Directory(storePath).listSync().whereType<File>())
          if (!p.basename(f.path).startsWith('.'))
            p.basename(f.path): await hashFile(f.path)
      };

  /// Archives [input] the way a CLI before schema 5 did.
  Future<String> writeLegacy(Map<String, dynamic> metadata,
      {String flavor = 'prod', String vc = '42'}) async {
    final dir = await temp.createTemp('legacy-');
    for (final name in payloadFiles(metadata)) {
      await File(p.join(input, name)).copy(p.join(dir.path, name));
    }
    final manifest = await createManifest(dir.path, metadata);
    await writeObject(p.join(dir.path, 'baseline.manifest.json'), manifest);
    final fp = manifest['fingerprint'] as String;
    final packed = p.join((await temp.createTemp('pack-')).path, 'b.tar.zst');
    await BaselineArchive().pack(dir.path, packed);
    await File(packed).copy(p.join(storePath, 'baseline-$fp.tar.zst'));
    await writeObject(p.join(storePath, sidecarName(flavor, vc, 'arm64-v8a')),
        sidecar(manifest));
    return fp;
  }

  /// Schema 3 build output whose policy binds [flavor]/[vc] unless [change]d.
  Future<Map<String, dynamic>> policyBuild(
      {String flavor = 'prod',
      String vc = '42',
      Map<String, String> change = const {}}) async {
    final key = base64Encode(List.filled(32, 1));
    final policy = HostPolicy({
      'schema': '1',
      'application_id': 'com.example.app',
      'version_code': vc,
      'channel': 'stable',
      'flavor': flavor,
      'abi': 'arm64-v8a',
      'strategy': 'bytecode',
      'fptc_key': base.testPublicKey,
      'root_key': key,
      'keys': 'one:$key',
      ...change,
    });
    await File(p.join(input, 'host_policy.json'))
        .writeAsString(policy.canonical);
    final m = base.metadata();
    await base.writeReceipt(input, versionCode: vc, overrides: {
      'host_policy_sha256': policy.digest,
      'fingerprint': fingerprint(
          await hashFile(p.join(input, 'app.dill')),
          m['engine_commit'] as String,
          await hashFile(p.join(input, 'dynamic_interface.yaml')),
          m['flutter_version'] as String,
          hostPolicyHash: policy.digest),
    });
    return {
      ...base.buildMetadata(),
      'schema': 3,
      'host_policy_sha256': policy.digest
    };
  }

  /// A second build of the same Dart sources: new libapp.so and APK.
  Future<void> nativeChange(String vc) async {
    await File(p.join(input, 'libapp.so')).writeAsString('native change $vc');
    await base.writeReceipt(input,
        versionCode: vc, overrides: {'apk_sha256': vc.padLeft(64, 'e')});
  }
}
