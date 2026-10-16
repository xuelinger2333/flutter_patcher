import 'dart:io';
import 'package:test/test.dart';
import 'package:flutter_patcher_cli/src/core.dart';
import 'package:flutter_patcher_cli/src/publish/store.dart';
import 'package:flutter_patcher_cli/src/publish/transaction.dart';
import 'package:flutter_patcher_cli/src/publish/retention.dart';

void main() {
  test('authorized flutterpatcher prefix: R2 CAS, publication gate and cleanup',
      () async {
    final prefix = Platform.environment['FLUTTER_PATCHER_TEST_R2_PREFIX']!;
    expect(RegExp(r'^cloud-test/[a-f0-9]{32}$').hasMatch(prefix), true);
    final root = await Directory.systemTemp.createTemp('publication-cloud-');
    addTearDown(() => root.delete(recursive: true));
    final commands = Commands(root.path);
    final uri = Uri.parse(
        's3://flutterpatcher/$prefix'); // Authorization is bucket-specific.
    final a = S3PublishStore(uri, commands, '${root.path}/a');
    final b = S3PublishStore(uri, commands, '${root.path}/b');
    expect(await a.list(), isEmpty);
    expect(await a.read('catalog.json'), isNull);
    final tx = PublicationTransaction(a, 'com.example.publication');
    final name = 'objects/${'a' * 32}/${digest([7])}.fptc';
    final receipt =
        await tx.run('a' * 32, {'cloud_fixture': true}, (catalog) async {
      expect(await a.write(name, [7], null), true);
      expect((await a.read(name))!.bytes, [7]);
      catalog['releases'] = {
        'a': {
          'object': name,
          'sha256': digest([7]),
          'size': 1,
          'created_at': 1,
          'pin': false
        }
      };
      return {'status': 'fixture_stored'};
    });
    expect(
        await tx.run('a' * 32, {'cloud_fixture': true},
            (_) async => throw StateError('must not repeat')),
        receipt);
    final old = (await a.read('catalog.json'))!;
    final race = await Future.wait([
      a.write('catalog.json', old.bytes.toList()..add(32), old.token),
      b.write('catalog.json', old.bytes.toList()..add(10), old.token)
    ]);
    expect(race.where((v) => v).length, 1);
    expect(await b.write('catalog.json', old.bytes, old.token), false);
    final cleaner = PublicationRetention(tx);
    final plan = cleaner.plan(await tx.snapshot(), 2);
    expect((plan['candidates'] as List).length, 1);
    expect(
        (await cleaner.execute('b' * 32, plan))['status'], 'cleanup_complete');
    expect(await a.read(name), isNull);
    expect(await a.list(), ['catalog.json']);
  },
      skip: Platform.environment['FLUTTER_PATCHER_TEST_R2_PREFIX'] == null
          ? 'Explicitly authorized R2 test prefix required'
          : false,
      timeout: const Timeout(Duration(minutes: 5)));
}
