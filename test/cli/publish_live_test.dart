import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:flutter_patcher/src/cli/core.dart';
import 'package:flutter_patcher/src/cli/baseline/repository.dart';
import 'package:flutter_patcher/src/cli/baseline/store.dart';
import 'package:flutter_patcher/src/cli/publish/command.dart';

import 'baseline_test.dart' as base;
import 'publication_baseline_test.dart' show testDraft;
import 'signers.dart';

/// Copies what devices download, as a developer uploads it to url.
Future<void> upload(String store, String live) async {
  for (final dir in ['objects', 'manifests']) {
    final from = Directory(p.join(store, dir));
    if (!from.existsSync()) continue;
    for (final file in from.listSync(recursive: true).whereType<File>()) {
      final to = File(p.join(live, p.relative(file.path, from: store)));
      await to.parent.create(recursive: true);
      await file.copy(to.path);
    }
  }
}

Map<String, dynamic> fieldsOf(File manifest) => jsonDecode(
  utf8.decode(
    base64Decode(
      (jsonDecode(manifest.readAsStringSync()) as Map)['payload'] as String,
    ),
  ),
) as Map<String, dynamic>;

void main() {
  test('publish numbers from what devices see at url when the catalog is '
      'lost, and refuses when url cannot be read', () async {
    final temp = await Directory.systemTemp.createTemp('publish-live-');
    addTearDown(() => temp.delete(recursive: true));
    const seed = 'nWGxne/9WmC6hEr0kuwsxERJxWl7MmkZcDusAxyuf2A=';
    const public = '11qYAYKxCrfVS/7TyWQHOg7hcvPapiMlrwIaaPcHURo=';
    final input = p.join(temp.path, 'input');
    await base.fixture(input);
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
    final baselines = p.join(temp.path, 'baselines');
    await Directory(baselines).create();
    final saved =
        await BaselineRepository(
          p.join(temp.path, 'save'),
          FileBaselineStore(baselines),
        ).save(
          input,
          {...base.metadata(), 'schema': 2, 'runtime_bootstrap': true},
          flavor: 'default',
          versionCode: '1',
        );

    // What devices download: a static host serving the uploaded files.
    final live = p.join(temp.path, 'live');
    await Directory(live).create();
    var serving = true;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      final file = File(p.join(live, request.uri.path.substring(1)));
      if (!serving) {
        request.response.statusCode = 503;
      } else if (file.existsSync()) {
        request.response.add(file.readAsBytesSync());
      } else {
        request.response.statusCode = 404;
      }
      await request.response.close();
    });

    final project = p.join(temp.path, 'project');
    final store = p.join(temp.path, 'publication');
    final keys = await writeTestKeys(
      project,
      seed,
      store: Directory(store).uri.toString(),
      baselineStore: Directory(baselines).uri.toString(),
    );
    await File(p.join(project, 'flutter_patcher.yaml')).writeAsString(
      'url: http://127.0.0.1:${server.port}\n',
      mode: FileMode.append,
    );

    // Each `patch` run writes a newer output directory.
    var outputs = 0;
    Future<void> makePatch() async {
      final out = p.join(
        project,
        '.dart_tool',
        'flutter_patcher',
        'patches',
        '${++outputs}',
      );
      await Directory(out).create(recursive: true);
      final draft = await testDraft(
        temp.path,
        fp,
        outputs,
        target: {
          'flavor': 'default',
          'version_code': '1',
          'abi': 'arm64-v8a',
          'release_manifest_sha256': saved['release']['manifest_sha256'],
        },
      );
      await draft.write(out);
      await writeObject(p.join(out, 'patch.json'), {
        'status': 'patch_created',
        'draft_sha256': draft.digest,
        'scope': {
          'application_id': 'com.example.app',
          'version_code': '1',
          'flavor': 'default',
          'fingerprint': fp,
          'strategy': 'bytecode',
          'channel': 'stable',
          'abi': 'arm64-v8a',
        },
      });
    }

    Future<Map<String, dynamic>> publish([List<String> extra = const []]) =>
        publication(
          publishOptions().parse([
            '--project',
            project,
            '--key-file',
            keys,
            '--yes',
            ...extra,
          ]),
        );
    File manifest() =>
        Directory(p.join(live, 'manifests'))
            .listSync()
            .whereType<File>()
            .single;

    // Nothing is live yet: the first patch is 1.
    await makePatch();
    expect((await publish())['patch_seq'], 1);
    await upload(store, live);
    expect(fieldsOf(manifest())['patch_seq'], '1');

    // The catalog is lost; devices may hold patch 1, so the next is 2.
    await Directory(store).delete(recursive: true);
    await makePatch();
    final second = await publish();
    expect(second['patch_seq'], 2);
    expect(second['revision'], 2);
    await upload(store, live);

    // Lost again: a withdrawal still covers everything devices may hold.
    await Directory(store).delete(recursive: true);
    final withdrawn = await publish(['--withdraw']);
    expect(withdrawn['action'], 'withdraw');
    await upload(store, live);
    expect(fieldsOf(manifest())['withdraw_through_seq'], '2');
    expect(fieldsOf(manifest())['revision'], '3');

    // A --seq at or below what devices may hold is refused.
    await makePatch();
    await expectLater(
      publish(['--seq', '2']),
      throwsA(
        isA<Failure>().having(
          (f) => f.code,
          'code',
          'PUBLISH_SEQUENCE_CONFLICT',
        ),
      ),
    );

    // Unreadable url: nothing is published rather than a guessed number.
    serving = false;
    await expectLater(
      publish(),
      throwsA(
        isA<Failure>().having((f) => f.code, 'code', 'PUBLISH_URL_UNREACHABLE'),
      ),
    );
    serving = true;
    expect((await publish())['patch_seq'], 3);
  });
}
