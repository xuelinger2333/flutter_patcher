import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:flutter_patcher/src/cli/core.dart';
import 'package:flutter_patcher/src/cli/run_work.dart';

void main() {
  late Directory temp;
  late String base;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('run-work-');
    base = p.join(temp.path, 'builds', 'run');
  });
  tearDown(() => temp.delete(recursive: true));

  List<String> runs() =>
      Directory(p.dirname(base))
          .listSync()
          .map((e) => p.basename(e.path))
          .toList()
        ..sort();

  Future<String> failed(int minutesAgo) async {
    final work = await RunWork.create(base);
    final marker = File(p.join(work, 'failure.json'))..writeAsStringSync('{}');
    await marker.setLastModified(
      DateTime.now().subtract(Duration(minutes: minutesAgo)),
    );
    return p.basename(work);
  }

  group('RunWork', () {
    test('a finished run removes its directory', () async {
      final work = await RunWork.create(base);
      File(p.join(work, '0-prepare.log')).writeAsStringSync('log');
      await RunWork.finish(work);
      expect(Directory(work).existsSync(), isFalse);
    });
    test('only the newest failed runs stay as evidence', () async {
      final names = [
        for (final age in [50, 40, 30, 20, 10]) await failed(age),
      ];
      await RunWork.create(base);
      final kept = runs();
      expect(kept, containsAll(names.skip(2)));
      expect(kept, isNot(contains(names[0])));
      expect(kept, isNot(contains(names[1])));
    });
    test('an unfinished run is kept until it is abandoned', () async {
      final running = p.basename(await RunWork.create(base));
      await RunWork.prune(base);
      expect(runs(), [running]);
      await RunWork.prune(
        base,
        now: DateTime.now().add(RunWork.abandoned + const Duration(hours: 1)),
      );
      expect(runs(), isEmpty);
    });
    test('other kinds of runs are left alone', () async {
      final other = Directory(p.join(p.dirname(base), 'other.pending-1-2'))
        ..createSync(recursive: true);
      await RunWork.prune(
        base,
        now: DateTime.now().add(const Duration(days: 30)),
      );
      expect(other.existsSync(), isTrue);
    });
  });

  group('failures', () {
    final full = Platform.isWindows ? 112 : 28;
    test('a full disk is reported as such, with its path', () {
      final error = FileSystemException(
        'writeFrom failed',
        r'C:\cache\run\analysis.dill',
        OSError('full', full),
      );
      final failure = unexpectedFailure('BUILD_FAILED', 'Build', error);
      expect(failure.code, 'DISK_FULL');
      expect(failure.message, contains('analysis.dill'));
    });
    test('file system errors name the path and the OS reason', () {
      final failure = unexpectedFailure(
        'BUILD_FAILED',
        'Build',
        FileSystemException('Cannot open file', '/x/y', OSError('Denied', 5)),
      );
      expect(failure.code, 'BUILD_FAILED');
      expect(failure.message, allOf(contains('/x/y'), contains('Denied')));
    });
    test('other errors never quote their text', () {
      final failure = unexpectedFailure(
        'PATCH_FAILED',
        'Patch',
        const FormatException('secret-key-bytes'),
      );
      expect(failure.message, 'Patch failed (FormatException).');
    });
    test('a failed step quotes its last lines', () {
      final failure = stepFailure(
        'BUILD_STEP_FAILED',
        'analysis',
        CommandResult(255, 'one\ntwo', 'three\nfour\n'),
        '/work',
      );
      expect(failure.code, 'BUILD_STEP_FAILED');
      expect(
        failure.message,
        'analysis failed (exit 255): three | four; evidence: /work',
      );
    });
    test('a step that ran out of space is a full disk', () {
      final failure = stepFailure(
        'BUILD_STEP_FAILED',
        'analysis',
        CommandResult(
          255,
          '',
          "Unhandled exception:\nFileSystemException: writeFrom failed, "
              "path = 'C:\\w\\analysis.dill' (OS Error: x, errno = $full)",
        ),
        '/work',
      );
      expect(failure.code, 'DISK_FULL');
      expect(
        failure.message,
        allOf(contains(r'C:\w\analysis.dill'), contains('/work')),
      );
    });
  });
}
