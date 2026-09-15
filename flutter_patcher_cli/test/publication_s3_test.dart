import 'dart:io';
import 'package:test/test.dart';
import 'package:flutter_patcher_cli/src/core.dart';
import 'package:flutter_patcher_cli/src/publish/store.dart';
import 'package:flutter_patcher_cli/src/publish/transaction.dart';

void main() {
  test(
      'real AWS CLI conditional writes, identity readback, listing and deletion',
      () async {
    final root = await Directory.systemTemp.createTemp('wp22-s3-');
    addTearDown(() => root.delete(recursive: true));
    final commands = Commands(root.path);
    commands.environment['FLUTTER_PATCHER_S3_ENDPOINT'] =
        Platform.environment['WP4_S3_TEST_ENDPOINT']!;
    final uri = Uri.parse(
        's3://wp4-test/publication-${DateTime.now().microsecondsSinceEpoch}');
    final a = S3PublishStore(uri, commands, '${root.path}/a');
    final b = S3PublishStore(uri, commands, '${root.path}/b');
    expect(await a.read('catalog.json'), isNull);
    expect(await a.write('catalog.json', [1], null), true);
    final old = (await a.read('catalog.json'))!;
    final race = await Future.wait([
      a.write('catalog.json', [2], old.token),
      b.write('catalog.json', [3], old.token)
    ]);
    expect(race.where((x) => x).length, 1);
    expect(await b.write('catalog.json', [4], old.token), false);
    final name = 'objects/${'a' * 32}/${digest([7])}.fptc';
    expect(await a.write(name, [7], null), true);
    expect(await b.write(name, [8], null), false);
    expect((await a.read(name))!.bytes, [7]);
    expect(await a.list(), containsAll(['catalog.json', name]));
    await a.delete(name);
    await a.delete(name);
    expect(await a.read(name), isNull);
  },
      skip: Platform.environment['WP4_S3_TEST_ENDPOINT'] == null
          ? 'Set isolated S3 endpoint and test credentials'
          : false,
      timeout: const Timeout(Duration(minutes: 3)));
}
