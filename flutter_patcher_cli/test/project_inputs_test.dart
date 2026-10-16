import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:flutter_patcher_cli/src/core.dart';
import 'package:flutter_patcher_cli/src/build/line_endings.dart';
import 'package:flutter_patcher_cli/src/build/workspace.dart';
import 'package:flutter_patcher_cli/src/sdk/package_inputs.dart';

Future<String> app(String name) async {
  final root = (await Directory.systemTemp.createTemp(name)).path;
  await File(p.join(root, 'app/pubspec.yaml'))
      .create(recursive: true)
      .then((f) => f.writeAsString('name: app\n'));
  return root;
}

Matcher failsWith(String code) =>
    throwsA(isA<Failure>().having((f) => f.code, 'code', code));

/// Windows junctions need no privilege, unlike symbolic links.
Future<void> junction(String link, String target) async {
  final result = await Process.run(
      'cmd', ['/c', 'mklink', '/J', p.normalize(link), p.normalize(target)]);
  expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
}

void main() {
  test('a directory differing from an excluded name only by case is rejected',
      () async {
    final root = await app('case-variant-');
    await Directory(p.join(root, 'app/build/outputs')).create(recursive: true);
    final work = BuildWorkspace(p.join(root, 'copy'));
    await work.copyPackage(p.join(root, 'app'), application: true);
    expect(await Directory(p.join(root, 'copy/project/build')).exists(), false);

    await Directory(p.join(root, 'app/lib/.Dart_Tool')).create(recursive: true);
    await expectLater(
        BuildWorkspace(p.join(root, 'copy2'))
            .copyPackage(p.join(root, 'app'), application: true),
        failsWith('BUILD_PROJECT_INVALID'));
  });

  test('native package inputs reject a case variant of a generated directory',
      () async {
    final root = (await Directory.systemTemp.createTemp('native-case-')).path;
    await File(p.join(root, 'pubspec.yaml')).writeAsString(
        'name: plugin\nversion: 1.0.0\nflutter:\n  plugin: {}\n');
    await Directory(p.join(root, 'android/Build')).create(recursive: true);
    final config = p.join(root, 'config.json');
    await writeObject(config, {
      'configVersion': 2,
      'packages': [
        {
          'name': 'plugin',
          'rootUri': Directory(root).uri.toString(),
          'packageUri': 'lib/'
        }
      ]
    });
    await expectLater(
        packageInputs(config), failsWith('PACKAGE_INPUT_INVALID'));
  });

  test('CRLF Dart sources are listed; excluded directories are ignored',
      () async {
    final root = await app('crlf-');
    final project = p.join(root, 'app');
    await File(p.join(project, 'lib/main.dart'))
        .create(recursive: true)
        .then((f) => f.writeAsString('void main() {}\n'));
    expect(await crlfDartSources(project), isEmpty);
    await File(p.join(project, 'lib/src/b.dart'))
        .create(recursive: true)
        .then((f) => f.writeAsBytes(utf8.encode('void b() {}\r\n')));
    await File(p.join(project, 'build/generated.dart'))
        .create(recursive: true)
        .then((f) => f.writeAsBytes(utf8.encode('void g() {}\r\n')));
    expect(await crlfDartSources(project), ['lib/src/b.dart']);
    expect(crlfWarning(['lib/src/b.dart']), contains('PATCH_NATIVE_CHANGE'));
  });

  test('a junction inside the project or the cache path is rejected', () async {
    final root = await app('junction-');
    final outside = p.join(root, 'outside');
    await Directory(outside).create();
    await junction(p.join(root, 'app/lib'), outside);
    await expectLater(
        BuildWorkspace(p.join(root, 'copy'))
            .copyPackage(p.join(root, 'app'), application: true),
        failsWith('BUILD_PROJECT_INVALID'));

    final cache = p.join(root, 'cache');
    await junction(cache, outside);
    await expectLater(
        rejectLinks(p.join(cache, 'doctor.lock')), failsWith('CACHE_INVALID'));
  }, skip: Platform.isWindows ? null : 'Junctions exist only on Windows');
}
