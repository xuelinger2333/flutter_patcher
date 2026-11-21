import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:flutter_patcher/src/cli/build/bootstrap.dart';
import 'package:flutter_patcher/src/cli/build/runtime_package.dart';
import 'package:flutter_patcher/src/cli/core.dart';

void main() {
  test(
    'runtime wrapper has stable source and lives only under isolated config',
    () async {
      final root = await Directory.systemTemp.createTemp('runtime-package-');
      final sources = <String>[];
      for (final sub in ['build', 'patch']) {
        final config = p.join(root.path, sub, '.dart_tool/package_config.json');
        await File(config).parent.create(recursive: true);
        await writeObject(config, {'configVersion': 2, 'packages': []});
        await installRuntimePackage(config, 'demo', 'main.dart');
        final rows = (await readObject(config))['packages'] as List;
        expect(rows.single['name'], 'dynamic_modules');
        final uri = Uri.parse(rows.single['rootUri'] as String);
        expect(p.isWithin(File(config).parent.path, uri.toFilePath()), isTrue);
        sources.add(
          await File.fromUri(uri.resolve('lib/host.dart')).readAsString(),
        );
        final loader = await File.fromUri(
          uri.resolve('lib/dynamic_modules.dart'),
        ).readAsString();
        expect(loader, contains('internal.loadDynamicModule(bytes: bytes)'));
        await expectLater(
          installRuntimePackage(config, 'demo', 'main.dart'),
          throwsA(isA<Failure>()),
        );
      }
      expect(sources[0], sources[1]);
      final source = bootstrapSource(
        'demo',
        'main.dart',
        'a' * 64,
        'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
      );
      expect(source, contains('loadModule: loadModule'));
      expect(source, isNot(contains('ensureInitialized')));
    },
  );

  group('addRuntimeDependency', () {
    const lock = """
packages:
  path:
    dependency: transitive
    description:
      name: path
      url: "https://pub.dev"
    source: hosted
    version: "1.9.1"
sdks:
  dart: ">=3.8.0 <4.0.0"
""";
    late Directory project;
    setUp(() async {
      project = await Directory.systemTemp.createTemp('runtime-dependency-');
      await File(p.join(project.path, 'pubspec.lock')).writeAsString(lock);
    });
    tearDown(() => project.delete(recursive: true));

    test('adds the runtime package by a path pub reads, offline', () async {
      List<String>? ran;
      await addRuntimeDependency(project.path, (arguments) async {
        ran = arguments;
        await File(p.join(project.path, 'pubspec.lock')).writeAsString(
          lock
              .replaceFirst(
                'packages:\n',
                'packages:\n  dynamic_modules:\n    dependency: "direct main"\n'
                    '    description:\n      path: ".dart_tool/flutter_patcher/runtime"\n'
                    '      relative: true\n    source: path\n    version: "1.0.0"\n',
              )
              .replaceFirst('">=3.8.0', '">=3.10.0'),
        );
      });
      expect(ran, [
        'add',
        '--offline',
        'dynamic_modules:{path: .dart_tool/flutter_patcher/runtime}',
      ]);
      expect(ran!.last, isNot(contains('"')));
    });

    test('fails when pub changes another locked package', () async {
      await expectLater(
        addRuntimeDependency(project.path, (_) async {
          await File(p.join(project.path, 'pubspec.lock'))
              .writeAsString(lock.replaceFirst('1.9.1', '1.9.2'));
        }),
        throwsA(
          isA<Failure>().having((f) => f.code, 'code', 'BUILD_STEP_FAILED'),
        ),
      );
    });
  });
}
