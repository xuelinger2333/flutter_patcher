import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:flutter_patcher/src/cli/core.dart';
import 'package:flutter_patcher/src/cli/sdk/artifacts.dart';
import 'package:flutter_patcher/src/cli/sdk/environment.dart';
import 'package:flutter_patcher/src/cli/sdk/host.dart';

// Fixtures describe a linux-x64 release; the host under test is pinned so the
// suite is host-independent.
final sdk = SdkIdentity('/selected/sdk', '3.47.2', 'a' * 40, '3.13.2', 'b' * 40,
    host: HostIdentity.linuxX64);
Map<String, dynamic> copy(Map<String, dynamic> input) =>
    jsonDecode(jsonEncode(input)) as Map<String, dynamic>;
Matcher failure(String code) =>
    isA<Failure>().having((e) => e.code, 'code', code);

class Fixture {
  final Map<String, List<int>> bytes = {};
  late Map<String, dynamic> engine, tools;

  /// The same release as a schema 1 manifest: one linux-x64 gen_snapshot
  /// without per-host verification fields.
  Map<String, dynamic> schema1() {
    final legacy = copy(engine);
    legacy['schema'] = 1;
    legacy['files'].removeLast();
    for (final key in ['verify', 'built_at', 'builder_repo_commit']) {
      legacy['files'][2].remove(key);
    }
    return legacy;
  }

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
    // A second host's gen_snapshot (PE header) that a linux-x64 CLI must skip.
    bytes['gen_snapshot-windows-x64.exe'] = [77, 90, ...List.filled(30, 0)];
    bytes['flutter_patcher_tools-3.47.2.dill'] = [144, 171, 205, 239, 1];
    Map<String, dynamic> record(String role, String name) => {
          'role': role,
          'name': name,
          'size': bytes[name]!.length,
          'sha256': sha256.convert(bytes[name]!).toString()
        };
    final common = {
      'schema': 2,
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
      'engine_api': 1,
      'capabilities': ['asset_overlay', 'isolate_entry'],
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
          'host_arch': 'x64',
          'built_at': '2026-09-07T16:28:58Z',
          'builder_repo_commit': 'c' * 40,
          'verify': {
            'snapshot': 'passed',
            'device': 'skipped',
            'device_reason': 'no_android_device'
          }
        },
        {
          ...record('gen_snapshot', 'gen_snapshot-windows-x64.exe'),
          'host_os': 'windows',
          'host_arch': 'x64',
          'built_at': '2026-09-19T08:00:00Z',
          'builder_repo_commit': 'c' * 40,
          'verify': {
            'snapshot': 'passed',
            'device': 'passed',
            'device_reason': null
          }
        }
      ]
    };
    tools = {
      ...common,
      'schema': 1,
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
    temp = await Directory.systemTemp.createTemp('artifacts-test-');
    fixture = Fixture();
  });
  tearDown(() async {
    await temp.delete(recursive: true);
  });

  test('independent builder commits are accepted', () {
    checkManifest(fixture.engine, 'engine', sdk);
    checkManifest(fixture.tools, 'tools', sdk);
  });
  test('schema 2 serves each listed host; other hosts are missing, not corrupt',
      () {
    final windows = SdkIdentity(
        sdk.root, sdk.version, sdk.engine, sdk.dartVersion, sdk.framework,
        host: const HostIdentity('windows', 'x64'));
    expect(windows.host.genSnapshotArtifact, 'gen_snapshot-windows-x64.exe');
    checkManifest(fixture.engine, 'engine', windows);
    checkManifest(fixture.tools, 'tools', windows);
    final macos = SdkIdentity(
        sdk.root, sdk.version, sdk.engine, sdk.dartVersion, sdk.framework,
        host: const HostIdentity('macos', 'arm64'));
    expect(() => checkManifest(fixture.engine, 'engine', macos),
        throwsA(failure('ENGINE_ARTIFACT_MISSING')));
    expect(hostFiles(fixture.engine, windows.host).map((r) => r['name']),
        isNot(contains('gen_snapshot-linux-x64')));
  });
  test('schema 1 releases stay readable and are linux-x64 only', () {
    final legacy = fixture.schema1();
    checkManifest(legacy, 'engine', sdk);
    final windows = SdkIdentity(
        sdk.root, sdk.version, sdk.engine, sdk.dartVersion, sdk.framework,
        host: const HostIdentity('windows', 'x64'));
    expect(() => checkManifest(legacy, 'engine', windows),
        throwsA(failure('ENGINE_ARTIFACT_MISSING')));
    final wrongHost = fixture.schema1();
    wrongHost['files'][2]['host_os'] = 'windows';
    expect(() => checkManifest(wrongHost, 'engine', sdk),
        throwsA(failure('ENGINE_MANIFEST_INVALID')));
  });
  final mutations = <String, void Function(Map<String, dynamic>)>{
    'unknown schema': (m) => m['schema'] = 3,
    'tools schema 2': (m) => m['schema'] = 1,
    'mixed engine': (m) => m['engine_commit'] = 'f' * 40,
    'wrong Flutter': (m) => m['flutter_version'] = '3.47.1',
    'wrong host': (m) => m['files'][2]['host_arch'] = 'arm64',
    'duplicate host': (m) => m['files'][3] = m['files'][2],
    'host verification pending': (m) =>
        m['files'][2]['verify']['device'] = 'pending',
    'host record without provenance': (m) =>
        m['files'][3].remove('builder_repo_commit'),
    'no primary gen_snapshot': (m) => m['files'].removeAt(2),
    'host record without verify': (m) => m['files'][2].remove('verify'),
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
      if (entry.key == 'tools schema 2') {
        final manifest = copy(fixture.tools);
        manifest['schema'] = 2;
        expect(() => checkManifest(manifest, 'tools', sdk),
            throwsA(failure('ENGINE_MANIFEST_INVALID')));
        return;
      }
      final manifest = copy(fixture.engine);
      entry.value(manifest);
      expect(() => checkManifest(manifest, 'engine', sdk),
          throwsA(failure('ENGINE_MANIFEST_INVALID')));
    });
  }
  test('missing required artifact is explicit', () {
    fixture.engine['files'].removeAt(1);
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
    await validateFiles(temp.path, fixture.engine, host: sdk.host);
    await validateFiles(temp.path, fixture.tools);
    await File(p.join(temp.path, 'gen_snapshot-linux-x64')).writeAsBytes([0]);
    await expectLater(validateFiles(temp.path, fixture.engine, host: sdk.host),
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

  test('an engine without the CLI\'s engine API is rejected', () {
    for (final mutate in <void Function(Map<String, dynamic>)>[
      (m) => m['engine_api'] = 2,
      (m) => m.remove('capabilities'),
      (m) => m['capabilities'] = ['Asset'],
    ]) {
      final manifest = copy(fixture.engine);
      mutate(manifest);
      expect(() => checkManifest(manifest, 'engine', sdk),
          throwsA(failure('ENGINE_MANIFEST_INVALID')));
    }
  });
  test('a release record round-trips and needs a well-formed tag', () {
    final release = ArtifactRelease('engine-3.47.2-930ce683', 'a' * 64);
    expect(release.kind, 'engine');
    expect(ArtifactRelease.fromJson(release.toJson()).tag, release.tag);
    for (final tag in ['flutter-3.47.2', 'engine-3.47-930ce683', 'ios-3.47.2-930ce683']) {
      expect(() => ArtifactRelease(tag, 'a' * 64),
          throwsA(failure('ENGINE_MANIFEST_INVALID')));
    }
  });

  group('HTTP artifact releases', () {
    late HttpServer server;
    late Downloads network;
    late ArtifactStore store;
    late Map<String, dynamic> index;
    var omitSnapshot = false;
    var corruptSnapshot = false;
    List<int> manifestBytes(Map<String, dynamic> m) => utf8.encode(jsonEncode(m));
    String digest(Map<String, dynamic> m) =>
        sha256.convert(manifestBytes(m)).toString();
    String toolsTag() =>
        'tools-3.47.2-${(fixture.tools['files'][0]['sha256'] as String).substring(0, 8)}';
    const engineTag = 'engine-3.47.2-930ce683';
    Map<String, dynamic> indexOf() => {
          'schema': 1,
          'flutter': {
            '3.47.2': {
              'current': {'engine': engineTag, 'tools': toolsTag()},
              'releases': {
                engineTag: {'kind': 'engine', 'manifest_sha256': digest(fixture.engine)},
                toolsTag(): {'kind': 'tools', 'manifest_sha256': digest(fixture.tools)},
              }
            }
          }
        };
    String cached(String tag, [String? host]) =>
        p.joinAll([temp.path, 'artifacts', tag, ?host]);
    setUp(() async {
      omitSnapshot = false;
      corruptSnapshot = false;
      index = indexOf();
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        final name = p.posix.basename(request.uri.path);
        List<int>? body;
        if (name == 'index.json') body = utf8.encode(jsonEncode(index));
        if (name == 'engine.manifest.json') body = manifestBytes(fixture.engine);
        if (name == 'tools.manifest.json') body = manifestBytes(fixture.tools);
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
          base.resolve('index.json'), network);
    });
    tearDown(() async {
      await server.close(force: true);
    });
    ArtifactStore offline() =>
        ArtifactStore(temp.path, store.base, store.index, Downloads(offline: true));

    test('a new host uses the current releases; a cached release needs no request',
        () async {
      await store.selectCurrent(sdk.version);
      expect(store.selected.keys, unorderedEquals(['engine', 'tools']));
      await store.obtain('engine', sdk);
      await store.obtain('tools', sdk);
      final count = network.requests;
      await store.obtain('engine', sdk);
      await store.obtain('tools', sdk);
      expect(network.requests, count);
      final local = offline();
      await local.selectCurrent(sdk.version);
      await local.obtain('tools', sdk);
      expect(local.downloads.requests, 0);
    });
    test('a baseline\'s releases need no index', () async {
      store.select([ArtifactRelease(toolsTag(), digest(fixture.tools))]);
      await store.obtain('tools', sdk);
      expect(network.requests, 2);
      await expectLater(
          store.obtain('engine', sdk), throwsA(failure('ENGINE_ARTIFACT_MISSING')));
    });
    test('an unsupported version names the supported ones', () async {
      await expectLater(
          store.selectCurrent('3.38.7'),
          throwsA(isA<Failure>()
              .having((e) => e.code, 'code', 'ENGINE_ARTIFACT_MISSING')
              .having((e) => e.message, 'message', contains('3.47.2'))));
      expect(network.requests, 1);
    });
    test('an unreachable index keeps the cached one; offline needs one', () async {
      await expectLater(offline().selectCurrent(sdk.version),
          throwsA(failure('ENGINE_ARTIFACT_MISSING')));
      await store.selectCurrent(sdk.version);
      await server.close(force: true);
      final again = ArtifactStore(temp.path, store.base, store.index, Downloads());
      await again.selectCurrent(sdk.version);
      expect(again.selected['engine']!.tag, engineTag);
    });
    test('an invalid index is never cached and can be retried', () async {
      index = {'schema': 1, 'flutter': {'3.47.2': {'current': {'engine': 'x'}, 'releases': {}}}};
      await expectLater(store.selectCurrent(sdk.version),
          throwsA(failure('ENGINE_MANIFEST_INVALID')));
      index = indexOf();
      await store.selectCurrent(sdk.version);
    });
    test('a manifest other than the recorded one is rejected', () async {
      await store.selectCurrent(sdk.version);
      fixture.tools['dart_sdk_commit'] = '2' * 40;
      await expectLater(
          store.obtain('tools', sdk), throwsA(failure('ARTIFACT_HASH_MISMATCH')));
      expect(Directory(cached(toolsTag())).existsSync(), isFalse);
    });
    test('a tag that does not name its manifest is rejected', () async {
      store.select([ArtifactRelease('engine-3.47.2-deadbeef', digest(fixture.engine))]);
      await expectLater(
          store.obtain('engine', sdk), throwsA(failure('ARTIFACT_HASH_MISMATCH')));
    });
    test('a failed or corrupt download never creates the cache', () async {
      await store.selectCurrent(sdk.version);
      omitSnapshot = true;
      await expectLater(
          store.obtain('engine', sdk), throwsA(failure('ENGINE_ARTIFACT_MISSING')));
      omitSnapshot = false;
      corruptSnapshot = true;
      await expectLater(
          store.obtain('engine', sdk), throwsA(failure('ARTIFACT_HASH_MISMATCH')));
      expect(Directory(cached(engineTag, 'linux-x64')).existsSync(), isFalse);
      corruptSnapshot = false;
      await store.obtain('engine', sdk);
    });
    test('only this host\'s gen_snapshot is downloaded and cached', () async {
      await store.selectCurrent(sdk.version);
      await store.obtain('engine', sdk);
      final cache = cached(engineTag, 'linux-x64');
      expect(File(p.join(cache, 'gen_snapshot-linux-x64')).existsSync(), isTrue);
      expect(File(p.join(cache, 'gen_snapshot-windows-x64.exe')).existsSync(),
          isFalse);
      expect(store.file(sdk, 'engine', 'gen_snapshot-linux-x64'),
          p.join(cache, 'gen_snapshot-linux-x64'));
      final windows = SdkIdentity(
          sdk.root, sdk.version, sdk.engine, sdk.dartVersion, sdk.framework,
          host: const HostIdentity('windows', 'x64'));
      await store.obtain('engine', windows);
      final windowsCache = cached(engineTag, 'windows-x64');
      expect(File(p.join(windowsCache, 'gen_snapshot-windows-x64.exe')).existsSync(),
          isTrue);
      expect(File(p.join(windowsCache, 'gen_snapshot-linux-x64')).existsSync(),
          isFalse);
    });
    test('corrupted cached file is quarantined and repaired online', () async {
      await store.selectCurrent(sdk.version);
      await store.obtain('engine', sdk);
      final path = store.file(sdk, 'engine', 'gen_snapshot-linux-x64');
      await File(path).writeAsBytes([1]);
      final local = offline()..select(store.selected.values);
      await expectLater(
          local.obtain('engine', sdk), throwsA(failure('ARTIFACT_HASH_MISMATCH')));
      await store.obtain('engine', sdk);
      expect(await File(path).readAsBytes(), fixture.bytes['gen_snapshot-linux-x64']);
      expect(
          Directory(p.dirname(p.dirname(path)))
              .listSync()
              .any((entry) => entry.path.contains('.invalid-')),
          isTrue);
    });
  });
}