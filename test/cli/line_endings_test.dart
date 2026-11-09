import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'package:flutter_patcher/src/cli/core.dart';
import 'package:flutter_patcher/src/cli/patch/pipeline.dart';
import 'package:flutter_patcher/src/cli/patch/rules.dart';

/// A checkout with other line endings than the release's: patch is refused
/// as before, but says that line endings are all that differ, and how to fix
/// it. Nothing warns about line endings before it matters.
void main() {
  late Directory root;
  setUp(() async => root = await Directory.systemTemp.createTemp('crlf-'));
  tearDown(() => root.delete(recursive: true));

  const gradle = 'android/app/build.gradle.kts',
      kotlin = 'android/app/src/main/kotlin/MainActivity.kt';
  String digest(String text) => sha256.convert(utf8.encode(text)).toString();
  void write(String name, String text) => File(p.join(root.path, name))
    ..createSync(recursive: true)
    ..writeAsStringSync(text);
  Map state(Map<String, String> files) => {
    'app': {
      'native_files': {for (final e in files.entries) e.key: digest(e.value)},
    },
  };

  Failure refusal(List<String> lineEndings) {
    final facts = PatchFacts('bytecode', 'android', 'work')
      ..appNativeChanged = true
      ..lineEndingChanges = lineEndings;
    try {
      PatchRules().check(PatchStage.inputs, facts);
    } on Failure catch (failure) {
      return failure;
    }
    fail('patch was not refused');
  }

  test('files built with CRLF and now LF are named, with the fix', () async {
    write(gradle, 'a\nb\n');
    write(kotlin, 'k\n');
    final found = await lineEndingChanges(
      root.path,
      state({gradle: 'a\nb\n', kotlin: 'k\n'}),
      state({gradle: 'a\r\nb\r\n', kotlin: 'k\r\n'}),
      'app',
    );
    expect(found, [gradle, kotlin]..sort());
    final failure = refusal(found);
    expect(failure.code, 'PATCH_NATIVE_CHANGE');
    expect(failure.message, contains('only in line endings'));
    expect(failure.message, contains(gradle));
    expect(failure.message, contains('core.autocrlf'));
  });

  test('files built with LF and now CRLF are named too', () async {
    write(gradle, 'a\r\nb\r\n');
    expect(
      await lineEndingChanges(
        root.path,
        state({gradle: 'a\r\nb\r\n'}),
        state({gradle: 'a\nb\n'}),
        'app',
      ),
      [gradle],
    );
  });

  test('a real change anywhere keeps the plain refusal', () async {
    write(gradle, 'a\nb\n');
    write(kotlin, 'changed\n');
    final found = await lineEndingChanges(
      root.path,
      state({gradle: 'a\nb\n', kotlin: 'changed\n'}),
      state({gradle: 'a\r\nb\r\n', kotlin: 'k\r\n'}),
      'app',
    );
    expect(found, isEmpty);
    expect(refusal(found).message, contains('rebuild host'));
    expect(refusal(found).message, isNot(contains('line endings')));
  });

  test('a new or removed native file is a real change', () async {
    write(gradle, 'a\n');
    expect(
      await lineEndingChanges(
        root.path,
        state({gradle: 'a\n', kotlin: 'k\n'}),
        state({gradle: 'a\r\n'}),
        'app',
      ),
      isEmpty,
    );
  });
}
