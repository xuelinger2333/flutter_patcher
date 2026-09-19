import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:flutter_patcher_cli/src/core.dart';
import 'package:flutter_patcher_cli/src/sdk/environment.dart';

class GitIdentity extends Commands {
  GitIdentity(super.cache);
  @override
  Future<String> run(String executable, List<String> args,
          {String? cwd,
          List<int>? inputBytes,
          String code = 'TOOL_FAILED',
          Duration timeout = const Duration(minutes: 15),
          Map<String, String>? extraEnvironment}) async =>
      'framework';
}

void main() {
  late Directory root;
  Future<void> write(String name, String content) async {
    final file = File(p.join(root.path, name));
    await file.parent.create(recursive: true);
    await file.writeAsString(content);
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('wp2-sdk-test-');
    for (final item in {
      'bin/internal/engine.version': 'engine',
      'bin/cache/engine.stamp': 'engine',
      'bin/cache/engine-dart-sdk.stamp': 'engine',
      'bin/cache/flutter_tools.stamp': 'framework:',
      'bin/cache/engine.realm': '',
      'packages/flutter_tools/pubspec.yaml': 'name: flutter_tools',
      'packages/flutter_tools/pubspec.lock': ''
    }.entries) {
      await write(item.key, item.value);
    }
  });
  tearDown(() => root.delete(recursive: true));
  test('initialized SDK passes read-only preflight', () async {
    await checkSdkReady(root.path, GitIdentity(root.path));
  });
  test('the stock Windows launcher stamp ":" is accepted only with its bug',
      () async {
    await write('bin/cache/flutter_tools.stamp', '":"');
    await expectLater(
        checkSdkReady(root.path, GitIdentity(root.path)),
        throwsA(isA<Failure>().having((e) => e.code, 'code', 'SDK_NOT_READY')));
    await write('bin/internal/shared.bat',
        "FOR /f %%r IN ('PUSHD %FLUTTER_ROOT% ^& \$git rev-parse HEAD') DO (");
    await checkSdkReady(root.path, GitIdentity(root.path));
    await write('bin/cache/flutter_tools.stamp', '"other:"');
    await expectLater(
        checkSdkReady(root.path, GitIdentity(root.path)),
        throwsA(isA<Failure>().having((e) => e.code, 'code', 'SDK_NOT_READY')));
  });
  for (final path in [
    'bin/cache/engine.stamp',
    'bin/cache/flutter_tools.stamp',
    'bin/cache/engine-dart-sdk.stamp'
  ]) {
    test('stale $path is refused before Flutter starts', () async {
      await write(path, 'stale');
      await expectLater(
          checkSdkReady(root.path, GitIdentity(root.path)),
          throwsA(
              isA<Failure>().having((e) => e.code, 'code', 'SDK_NOT_READY')));
    });
  }
}
