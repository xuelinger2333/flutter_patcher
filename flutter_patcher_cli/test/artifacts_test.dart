import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:flutter_patcher_cli/src/core.dart';
import 'package:flutter_patcher_cli/src/sdk/artifacts.dart';
import 'package:flutter_patcher_cli/src/sdk/environment.dart';

final sdk =
    SdkIdentity('/selected/sdk', '3.47.2', 'a' * 40, '3.13.2', 'b' * 40);
Map<String, dynamic> copy(Map<String, dynamic> input) =>
    jsonDecode(jsonEncode(input)) as Map<String, dynamic>;
Matcher failure(String code) =>
    isA<Failure>().having((e) => e.code, 'code', code);

class Fixture {
  final Map<String, List<int>> bytes = {};
  late Map<String, dynamic> engine, tools;
  Fixture() {
    final so = List<int>.filled(32, 0)
      ..setRange(0, 6, [127, 69, 76, 70, 2, 1])
      ..[18] = 183;
    final snapshot = List<int>.from(so)..[18] = 62;
    bytes['libflutter-arm64_v8a-release.jar'] = ZipEncoder().encode(Archive()
      ..addFile(ArchiveFile('lib/arm64-v8a/libflutter.so', so.length, so)));
    bytes['flutter_embedding_release.jar'] = ZipEncoder().encode(Archive()
      ..addFile(
          ArchiveFile('io/flutter/embedding/engine/FlutterJNI.class', 1, [0])));
    bytes['gen_snapshot-linux-x64'] = snapshot;
    bytes['flutter_patcher_tools-3.47.2.dill'] = [144, 171, 205, 239, 1];
    Map<String, dynamic> record(String role, String name) => {
          'role': role,
          'name': name,
          'size': bytes[name]!.length,
          'sha256': sha256.convert(bytes[name]!).toString()
        };
    final common = {
      'schema': 1,
      'flutter_version': sdk.version,
      'engine_commit': sdk.engine,
      'builder_repo_commit': 'c' * 40,
      'patches': [
        {'file': 'p.patch', 'sha256': 'd' * 64}
      ]
    };
    engine = {
      ...common,
      'engine_stamp': sdk.engine,
      'depot_tools_rev': 'e' * 40,
      'build_id': '930ce683-2072-4028-ba2c-e739451cf2a1',
      'built_at': '2026-09-07T16:28:58Z',
      'verify': {
        'snapshot': 'passed',
        'device': 'skipped',
        'device_reason': 'no_android_device'
      },
      'files': [
        {
          ...record('engine', 'libflutter-arm64_v8a-release.jar'),
          'abi': 'arm64-v8a',
          'maven': 'io.flutter:arm64_v8a_release:1.0.0-${sdk.engine}',
          'contents': [
            {
              'name': 'lib/arm64-v8a/libflutter.so',
              'size': so.length,
              'sha256': sha256.convert(so).toString()
            }
          ]
        },
        {
          ...record('embedding', 'flutter_embedding_release.jar'),
          'maven': 'io.flutter:flutter_embedding_release:1.0.0-${sdk.engine}'
        },
        {
          ...record('gen_snapshot', 'gen_snapshot-linux-x64'),
          'host_os': 'linux',
          'host_arch': 'x64'
        }
      ]
    };
    tools = {
      ...common,
      'builder_repo_commit': 'f' * 40,
      'dart_version': sdk.dartVersion,
      'dart_sdk_commit': '1' * 40,
      'files': [record('tools', 'flutter_patcher_tools-3.47.2.dill')]
    };
  }
}

void main() {
  late Directory temp;
  late Fixture fixture;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('wp2-test-');
    fixture = Fixture();
  });
  tearDown(() async {
    await temp.delete(recursive: true);
  });

  test('independent builder commits are accepted', () {
    checkManifest(fixture.engine, 'engine', sdk);
    checkManifest(fixture.tools, 'tools', sdk);
  });
  final mutations = <String, void Function(Map<String, dynamic>)>{
    'unknown schema': (m) => m['schema'] = 2,
    'mixed engine': (m) => m['engine_commit'] = 'f' * 40,
    'wrong Flutter': (m) => m['flutter_version'] = '3.47.1',
    'wrong host': (m) => m['files'][2]['host_arch'] = 'arm64',
    'path traversal': (m) => m['files'][0]['name'] = '../escape.jar',
    'negative size': (m) => m['files'][0]['size'] = -1,
    'duplicate role': (m) => m['files'][2] = m['files'][0],
    'wrong Maven stamp': (m) =>
        m['files'][0]['maven'] = 'io.flutter:arm64_v8a_release:stock',
    'not a UUID v4': (m) => m['build_id'] = 'ELF-BUILD-ID',
    'snapshot failed': (m) => m['verify']['snapshot'] = 'failed',
    'unauthorized is not skipped': (m) =>
        m['verify']['device_reason'] = 'unauthorized',
    'missing patch hash': (m) => m['patches'][0].remove('sha256'),
  };
  for (final entry in mutations.entries) {
    test('rejects ${entry.key}', () {
      final manifest = copy(fixture.engine);
      entry.value(manifest);
      expect(() => checkManifest(manifest, 'engine', sdk),
          throwsA(failure('ENGINE_MANIFEST_INVALID')));
    });
  }
  test('missing required artifact is explicit', () {
    fixture.engine['files'].removeLast();
    expect(() => checkManifest(fixture.engine, 'engine', sdk),
        throwsA(failure('ENGINE_ARTIFACT_MISSING')));
  });
  test('old multi-dill/YAML tools schema is rejected', () {
    fixture.tools['files'].add({'role': 'protocol_interface'});
    expect(() => checkManifest(fixture.tools, 'tools', sdk),
        throwsA(failure('TOOLS_ARTIFACT_MISSING')));
  });
  test('tools Dart mismatch is rejected', () {
    fixture.tools['dart_version'] = '3.10.7';
    expect(() => checkManifest(fixture.tools, 'tools', sdk),
        throwsA(failure('ENGINE_MANIFEST_INVALID')));
  });
  test('duplicate JSON fields are rejected', () async {
    final file = File(p.join(temp.path, 'bad.json'));
    await file.writeAsString('{"schema":2,"schema":1}');
    await expectLater(
        readObject(file.path), throwsA(failure('ENGINE_MANIFEST_INVALID')));
  });
  test('valid binaries and actual corrupted binary', () async {
    for (final entry in fixture.bytes.entries) {
      await File(p.join(temp.path, entry.key)).writeAsBytes(entry.value);
    }
    await validateFiles(temp.path, fixture.engine);
    await validateFiles(temp.path, fixture.tools);
    await File(p.join(temp.path, 'gen_snapshot-linux-x64')).writeAsBytes([0]);
    await expectLater(validateFiles(temp.path, fixture.engine),
        throwsA(failure('ARTIFACT_HASH_MISMATCH')));
  });
  test('APK check uses inner SO hash, never the jar hash', () async {
    final apk = File(p.join(temp.path, 'test.apk'));
    await apk.writeAsBytes(fixture.bytes['libflutter-arm64_v8a-release.jar']!);
    await verifyApk(apk.path, fixture.engine);
    final wrong = copy(fixture.engine);
    wrong['files'][0]['contents'][0]['sha256'] = wrong['files'][0]['sha256'];
    await expectLater(verifyApk(apk.path, wrong),
        throwsA(failure('ENGINE_INJECTION_FAILED')));
  });
  test('insecure non-loopback URLs and embedded credentials are rejected', () {
    expect(() => Downloads.validateUri(Uri.parse('http://example.com/a')),
        throwsA(failure('CONFIG_INVALID')));
    expect(
        () => Downloads.validateUri(Uri.parse('https://secret@example.com/a')),
        throwsA(failure('CONFIG_INVALID')));
  });

  group('HTTP artifact cache', () {
    late HttpServer server;
    late Downloads network;
    late ArtifactStore store;
    var omitSnapshot = false;
    var corruptSnapshot = false;
    var supported = '3.47.2\n';
    setUp(() async {
      omitSnapshot = false;
      corruptSnapshot = false;
      supported = '3.47.2\n';
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        final name = p.posix.basename(request.uri.path);
        List<int>? body;
        if (name == 'supported_versions.txt') body = utf8.encode(supported);
        if (name == 'engine.manifest.json') {
          body = utf8.encode(jsonEncode(fixture.engine));
        }
        if (name == 'tools.manifest.json') {
          body = utf8.encode(jsonEncode(fixture.tools));
        }
        body ??= fixture.bytes[name];
        if (name == 'gen_snapshot-linux-x64' && omitSnapshot) body = null;
        if (name == 'gen_snapshot-linux-x64' && corruptSnapshot) body = [0];
        if (body == null) {
          request.response.statusCode = 404;
        } else {
          request.response.add(body);
        }
        await request.response.close();
      });
      network = Downloads();
      final base = Uri.parse('http://127.0.0.1:${server.port}/');
      store = ArtifactStore(temp.path, base.resolve('releases'),
          base.resolve('supported_versions.txt'), network);
    });
    tearDown(() async {
      await server.close(force: true);
    });
    test('cold download, warm hit, offline use without HTTP', () async {
      await store.checkSupport(sdk.version);
      await store.obtain('engine', sdk);
      await store.obtain('tools', sdk);
      final count = network.requests;
      await store.checkSupport(sdk.version);
      await store.obtain('engine', sdk);
      expect(network.requests, count);
      final offline = ArtifactStore(
          temp.path, store.base, store.supportUri, Downloads(offline: true));
      await offline.checkSupport(sdk.version);
      await offline.obtain('tools', sdk);
      expect(offline.downloads.requests, 0);
    });
    test('unsupported versions stop before any artifact request', () async {
      await expectLater(store.checkSupport('3.38.7'),
          throwsA(failure('ENGINE_ARTIFACT_MISSING')));
      expect(network.requests, 1);
    });
    test('failed refresh preserves previously verified tools', () async {
      await store.obtain('tools', sdk);
      final name = 'flutter_patcher_tools-${sdk.version}.dill';
      final oldBytes = await File(store.file(sdk, 'tools', name)).readAsBytes();
      fixture.bytes[name] = [0];
      await expectLater(
          store.obtain('tools', sdk, refresh: true), throwsA(isA<Failure>()));
      expect(
          await File(store.file(sdk, 'tools', name)).readAsBytes(), oldBytes);
      final offline = ArtifactStore(
          temp.path, store.base, store.supportUri, Downloads(offline: true));
      await offline.obtain('tools', sdk);
      await expectLater(offline.obtain('tools', sdk, refresh: true),
          throwsA(failure('CONFIG_INVALID')));
    });
    test('successful refresh fetches tools again without touching engine',
        () async {
      await store.obtain('engine', sdk);
      await store.obtain('tools', sdk);
      final count = network.requests;
      await store.obtain('tools', sdk, refresh: true);
      expect(network.requests, count + 2);
      await store.obtain('engine', sdk);
      expect(network.requests, count + 2);
    });
    test('refreshes a cached support table for a newly supported version',
        () async {
      await store.checkSupport('3.47.2');
      supported = '3.47.2\n3.47.3\n';
      await store.checkSupport('3.47.3');
      expect(network.requests, 2);
    });
    test('invalid support table is never committed and can be retried',
        () async {
      supported = '<html>error</html>';
      await expectLater(store.checkSupport('3.47.2'),
          throwsA(failure('ENGINE_MANIFEST_INVALID')));
      supported = '3.47.2\n';
      await store.checkSupport('3.47.2');
      expect(network.requests, 2);
    });
    test('failed download never creates the usable cache directory', () async {
      omitSnapshot = true;
      await expectLater(store.obtain('engine', sdk),
          throwsA(failure('ENGINE_ARTIFACT_MISSING')));
      expect(
          Directory(p.join(temp.path, 'artifacts/3.47.2/engine')).existsSync(),
          isFalse);
      omitSnapshot = false;
      await store.obtain('engine', sdk);
    });
    test('bad bytes fail before cache commit', () async {
      corruptSnapshot = true;
      await expectLater(store.obtain('engine', sdk),
          throwsA(failure('ARTIFACT_HASH_MISMATCH')));
      expect(
          Directory(p.join(temp.path, 'artifacts/3.47.2/engine')).existsSync(),
          isFalse);
    });
    test('corrupted cached file is quarantined and repaired online', () async {
      await store.obtain('engine', sdk);
      final path = store.file(sdk, 'engine', 'gen_snapshot-linux-x64');
      await File(path).writeAsBytes([1]);
      final offline = ArtifactStore(
          temp.path, store.base, store.supportUri, Downloads(offline: true));
      await expectLater(offline.obtain('engine', sdk),
          throwsA(failure('ARTIFACT_HASH_MISMATCH')));
      await store.obtain('engine', sdk);
      expect(await File(path).readAsBytes(),
          fixture.bytes['gen_snapshot-linux-x64']);
      expect(
          Directory(p.dirname(p.dirname(path)))
              .listSync()
              .any((entry) => entry.path.contains('.invalid-')),
          isTrue);
    });
  });
}
