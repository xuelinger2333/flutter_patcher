import 'dart:io';
import 'dart:typed_data';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'host_tools.dart';
import 'package:flutter_patcher_cli/src/core.dart';
import 'package:flutter_patcher_cli/src/baseline/repository.dart';
import 'package:flutter_patcher_cli/src/baseline/store.dart';
import 'package:flutter_patcher_cli/src/publish/pipeline.dart';
import 'package:flutter_patcher_cli/src/publish/transaction.dart';
import 'package:flutter_patcher_cli/src/crypto/signing.dart';
import 'package:flutter_patcher_cli/src/cli.dart';
import 'baseline_test.dart' as base;

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
      'runtime_bootstrap': true
    };
    final fp = (await readObject(
        p.join(input, 'baseline.manifest.json')))['fingerprint'] as String;
    await writeObject(
        p.join(input, 'compiler_interface.json'), {'callable': <Object>[]});
    await writeObject(p.join(input, 'build_receipt.json'), {
      'runtime_bootstrap': true,
      'app_only': true,
      'apk_sha256': 'd' * 64,
      'interface_sha256':
          await hashFile(p.join(input, 'dynamic_interface.yaml')),
      'libapp_sha256': await hashFile(p.join(input, 'libapp.so')),
      'fingerprint': fp,
      'application_id': 'com.example.app',
      'version_code': '1',
      'public_key': public,
    });
    await Directory(p.join(temp.path, 'store')).create();
    final store = FileBaselineStore(p.join(temp.path, 'store'));
    await BaselineRepository(p.join(temp.path, 'save'), store)
        .save(input, metadata, flavor: 'default', versionCode: '1');
    final fields = {
      'application_id': 'com.example.app',
      'version_code': '1',
      'flavor': 'default',
      'fingerprint': fp
    };
    expect(
        (await publicationBaseline(
            store, fields, p.join(temp.path, 'fetch')))['fingerprint'],
        fp);
    await expectLater(
        publicationBaseline(store, {...fields, 'application_id': 'other.app'},
            p.join(temp.path, 'wrong')),
        throwsA(isA<Failure>()));
    final h = (ByteData(82)
          ..setUint32(0, 0x46505443)
          ..setUint16(4, 1)
          ..setUint32(38, 1)
          ..setUint64(42, 1))
        .buffer
        .asUint8List();
    h.setRange(6, 38, hexBytes(fp));
    h.setRange(50, 82, hexBytes(digest([7])));
    final signature = signMessage([...h, 7], seed, public);
    final patch = File(p.join(temp.path, 'patch.fptc'));
    await patch.writeAsBytes([...h, ...signature, 7]);
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
      'public_base_url': 'https://example.com/publication',
      'private_key': priv.path,
      'public_key': pub.path,
      'patch': patch.path,
      'expected_revision': 0,
      'created_at': 1,
      'cache_dir': p.join(
          Directory.current.path,
          '.dart_tool',
          'flutter_patcher',
          'publication-test-${DateTime.now().microsecondsSinceEpoch}'),
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
        'revision': '1'
      },
    });
    expect(await runCli(['publish', '--production', '--request', req.path]), 0);
    expect(
        await runCli([
          'publish',
          '--production',
          '--request',
          req.path,
          '--action',
          'withdraw',
          '--commit'
        ]),
        2);
    expect(
        await File(p.join(temp.path, 'publication', 'catalog.json')).exists(),
        false);
    expect(
        await runCli(
            ['publish', '--production', '--request', req.path, '--commit']),
        0);
    expect(
        await runCli(
            ['publish', '--production', '--request', req.path, '--commit']),
        0);
    await File(p.join(temp.path, 'store', 'baseline-$fp.tar.zst')).delete();
    await expectLater(
        publicationBaseline(store, fields, p.join(temp.path, 'new-fetch')),
        throwsA(isA<Failure>()));
    // The previous successful cache still exists, but a fresh verification cannot use it.
    expect(
        await Directory(p.join(temp.path, 'fetch', 'baseline-cache', fp))
            .exists(),
        true);
  }, tags: 'zstd', skip: skipUnless('zstd') ?? false);
}
