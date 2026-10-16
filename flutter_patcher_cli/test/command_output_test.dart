import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:flutter_patcher_cli/src/core.dart';

void main() {
  test('tool output that is not UTF-8 is decoded instead of aborting',
      () async {
    expect(await collectOutput(Stream.value(utf8.encode('ok ✓'))), 'ok ✓');
    // "你好" in GBK, as Windows prints its own errors on a Chinese system.
    final text = await collectOutput(Stream.fromIterable([
      [0xc4, 0xe3],
      [0xba, 0xc3]
    ]));
    expect(text, isNotEmpty);
  });

  test('a batch launcher under a spaced path receives spaced arguments',
      () async {
    final root = (await Directory.systemTemp.createTemp('launcher ')).path;
    final launcher = p.join(root, 'tool dir', 'echo.bat');
    await File(launcher).create(recursive: true);
    await File(launcher).writeAsString('@echo off\r\necho [%~1][%~2]\r\n');
    final result = await Commands(root)
        .runResult(launcher, [p.join(root, 'a b'), 'plain']);
    expect(result.exitCode, 0, reason: result.stderr);
    expect(result.stdout.trim(), '[${p.join(root, 'a b')}][plain]');
  }, skip: Platform.isWindows ? null : 'Batch launchers exist only on Windows');
}
