import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'host_tools.dart';
import 'package:flutter_patcher_cli/src/core.dart';
import 'package:flutter_patcher_cli/src/baseline/manifest.dart';
import 'package:flutter_patcher_cli/src/baseline/repository.dart';
import 'package:flutter_patcher_cli/src/baseline/store.dart';
import 'baseline_test.dart' show fixture, metadata;

void main() {
  late Directory temp;
  late HttpServer server;
  late HttpBaselineStore store;
  final objects = <String, List<int>>{};
  var rejectPut = false, redirect = false, rejectAuth = false;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('baseline-store-test-');
    objects.clear();
    rejectPut = false;
    redirect = false;
    rejectAuth = false;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    store = HttpBaselineStore(
        Uri.parse('http://127.0.0.1:${server.port}/store'),
        token: 'test-secret');
    server.listen((request) async {
      if (redirect) {
        request.response.statusCode = 307;
        request.response.headers
            .set('location', 'https://example.invalid/credentials');
      } else if (rejectAuth ||
          request.headers.value('authorization') != 'Bearer test-secret') {
        request.response.statusCode = 403;
      } else if (request.method == 'HEAD') {
        request.response.statusCode = 200;
      } else if (request.method == 'PUT') {
        final bytes = await request.fold<List<int>>([], (a, b) => a..addAll(b));
        if (rejectPut) {
          request.response.statusCode = 503;
        } else if (request.headers.value('if-none-match') != '*') {
          request.response.statusCode = 400;
        } else if (objects.containsKey(request.uri.path)) {
          request.response.statusCode = 412;
        } else {
          objects[request.uri.path] = bytes;
          request.response.statusCode = 201;
        }
      } else if (objects.containsKey(request.uri.path)) {
        request.response.add(objects[request.uri.path]!);
      } else {
        request.response.statusCode = 404;
      }
      await request.response.close();
    });
  });
  tearDown(() => server.close(force: true));
  test('authenticated GET/HEAD/conditional PUT and missing object', () async {
    final source = File(p.join(temp.path, 'source'));
    await source.writeAsString('original');
    final name = 'baseline-${'a' * 64}.tar.zst';
    await store.probe();
    expect(await store.put(name, source.path), true);
    await source.writeAsString('different');
    expect(await store.put(name, source.path), false);
    final dest = p.join(temp.path, 'download');
    expect(await store.get(name, dest), true);
    expect(await File(dest).readAsString(), 'original');
    expect(
        await store.get(
            'baseline-${'b' * 64}.tar.zst', p.join(temp.path, 'missing')),
        false);
  });
  test('redirects and auth failures are explicit and do not disclose token',
      () async {
    redirect = true;
    await expectLater(
        store.probe(),
        throwsA(isA<Failure>().having(
            (e) => e.message.contains('test-secret'), 'secret leaked', false)));
    redirect = false;
    rejectAuth = true;
    await expectLater(store.probe(), throwsA(isA<Failure>()));
  });
  test('upload error propagates without sidecar', () async {
    final source = p.join(temp.path, 'source');
    await File(source).writeAsString('bytes');
    rejectPut = true;
    await expectLater(store.put('baseline-${'c' * 64}.tar.zst', source),
        throwsA(isA<Failure>()));
    expect(objects, isEmpty);
  });
  test('HTTP complete archive roundtrip into independent cache', () async {
    final input = p.join(temp.path, 'input');
    await fixture(input);
    final first = BaselineRepository(p.join(temp.path, 'one'), store);
    final saved = await first.save(input, metadata(),
        flavor: 'default', versionCode: '1');
    final second = BaselineRepository(p.join(temp.path, 'two'), store);
    final restored = await second.fetch(saved['fingerprint'] as String);
    expect(canonical(await verifyBaseline(restored)),
        canonical(await verifyBaseline(input)));
    await first.save(input, metadata(), flavor: 'default', versionCode: '1');
  }, tags: 'zstd', skip: skipUnless('zstd') ?? false);

  test(
      'real AWS CLI with isolated S3 emulator: roundtrip, conflict and missing',
      () async {
    final commands = Commands(temp.path);
    commands.environment['FLUTTER_PATCHER_S3_ENDPOINT'] =
        Platform.environment['FLUTTER_PATCHER_TEST_S3_ENDPOINT']!;
    final s3 = S3BaselineStore(
        Uri.parse(
            's3://flutter-patcher-test/${DateTime.now().microsecondsSinceEpoch}'),
        commands);
    await s3.probe();
    final input = p.join(temp.path, 'input');
    await fixture(input);
    final first = BaselineRepository(p.join(temp.path, 's3-one'), s3);
    final saved = await first.save(input, metadata(),
        flavor: 'default', versionCode: '1');
    await first.save(input, metadata(), flavor: 'default', versionCode: '1');
    final second = BaselineRepository(p.join(temp.path, 's3-two'), s3);
    await verifyBaseline(await second.fetch(saved['fingerprint'] as String));
    expect(
        await s3.get(
            'baseline-${'e' * 64}.tar.zst', p.join(temp.path, 'missing')),
        false);
    await File(p.join(input, 'libapp.so')).writeAsString('new');
    await expectLater(
        first.save(input, metadata(), flavor: 'default', versionCode: '2'),
        throwsA(isA<Failure>()
            .having((e) => e.code, 'code', 'BASELINE_CONTENT_CONFLICT')));
    final unavailable =
        S3BaselineStore(Uri.parse('s3://missing-test-bucket'), commands);
    await expectLater(unavailable.probe(), throwsA(isA<Failure>()));
  },
      skip: Platform.environment['FLUTTER_PATCHER_TEST_S3_ENDPOINT'] == null
          ? 'Set isolated S3 emulator endpoint and test-only AWS credentials'
          : false,
      timeout: const Timeout(Duration(minutes: 3)));
}
