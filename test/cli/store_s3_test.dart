import 'dart:io';

import 'package:test/test.dart';
import 'package:flutter_patcher/src/cli/core.dart';
import 'package:flutter_patcher/src/cli/publish/store.dart';

/// publish replaces a patch file in S3 only over the one it read: a real
/// AWS CLI against an isolated emulator (test/acceptance/linux_tests.py).
void main() {
  test(
    'real AWS CLI conditional writes and readback of a patch file',
    () async {
      final root = await Directory.systemTemp.createTemp('store-s3-');
      addTearDown(() => root.delete(recursive: true));
      final commands = Commands(root.path);
      commands.environment['FLUTTER_PATCHER_S3_ENDPOINT'] =
          Platform.environment['FLUTTER_PATCHER_TEST_S3_ENDPOINT']!;
      final uri = Uri.parse(
        's3://flutter-patcher-test/patches-${DateTime.now().microsecondsSinceEpoch}',
      );
      final a = S3PublishStore(uri, commands, '${root.path}/a');
      final b = S3PublishStore(uri, commands, '${root.path}/b');
      const name = '7-default-production-arm64-v8a.fptc';
      expect(await a.read(name), isNull);
      expect(await a.write(name, [1], null), isTrue);
      expect(await b.write(name, [9], null), isFalse);
      final old = (await a.read(name))!;
      expect(old.bytes, [1]);
      final race = await Future.wait([
        a.write(name, [2], old.token),
        b.write(name, [3], old.token),
      ]);
      expect(race.where((x) => x).length, 1);
      expect(await b.write(name, [4], old.token), isFalse);
      expect((await a.read(name))!.bytes, anyOf(equals([2]), equals([3])));
      expect(() => a.read('catalog.json'), throwsA(isA<Failure>()));
    },
    skip: Platform.environment['FLUTTER_PATCHER_TEST_S3_ENDPOINT'] == null
        ? 'Set isolated S3 endpoint and test credentials'
        : false,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
