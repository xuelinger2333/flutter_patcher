import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:flutter_patcher/src/cli/core.dart';
import 'package:flutter_patcher/src/cli/patch/sources.dart';

import 'host_tools.dart';

void main() {
  late Directory root;
  late String config;
  final sources = <String, String>{};

  Future<void> file(String uri, String source) async {
    final parsed = Uri.parse(uri);
    final path = p.join(
      root.path,
      parsed.pathSegments.first,
      'lib',
      parsed.pathSegments.skip(1).join('/'),
    );
    await File(path).parent.create(recursive: true);
    await File(path).writeAsString(source);
    sources[uri] = source;
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('incremental-sources-');
    sources.clear();
    config = p.join(root.path, 'package_config.json');
    await writeObject(config, {
      'configVersion': 2,
      'packages': [
        for (final name in ['app', 'dep', 'host'])
          {
            'name': name,
            'rootUri': Directory(p.join(root.path, name)).uri.toString(),
            'packageUri': 'lib/',
            'languageVersion': '3.13',
          },
      ],
    });
    for (final name in ['app', 'dep', 'host']) {
      await Directory(p.join(root.path, name, 'lib')).create(recursive: true);
    }
  });
  tearDown(() => root.delete(recursive: true));

  Future<Set<String>> select(List<String> changed, {Set<String>? baseline}) =>
      selectPatchSources(
        config: config,
        packages: {'app', 'dep'},
        changed: changed,
        baselineSources: baseline ?? sources.keys.toSet(),
        entry: 'package:app/main.dart',
      );

  test(
    'a leaf change carries its callers and reuses unrelated libraries',
    () async {
      await file(
        'package:app/main.dart',
        "import 'screen.dart'; import 'stable.dart'; void main() => print(screen() + stable());",
      );
      await file(
        'package:app/screen.dart',
        "import 'leaf.dart'; String screen() => leaf();",
      );
      await file('package:app/leaf.dart', "String leaf() => 'patched '; ");
      await file('package:app/stable.dart', "String stable() => 'host';");
      await file('package:app/unused.dart', "String unused() => 'unused';");
      final selected = await select(['package:app/leaf.dart']);
      expect(selected, {
        'package:app/main.dart',
        'package:app/screen.dart',
        'package:app/leaf.dart',
      });
      final output = p.join(root.path, 'module');
      final remap = await remapSources(config, output, {'app'}, 9, selected);
      expect(
        (await packageRoots(remap['packages'] as String)).keys,
        containsAll(['app', 'patch.9.app', 'dep', 'host']),
      );
      expect(File(p.join(output, 'app/stable.dart')).existsSync(), isFalse);
      expect(File(p.join(output, 'app/unused.dart')).existsSync(), isFalse);
      expect(
        await File(p.join(output, 'app/main.dart')).readAsString(),
        contains("import 'package:app/stable.dart'"),
      );
      final run = await Process.run(dartVm, [
        '--packages=${remap['packages']}',
        p.join(output, 'app/main.dart'),
      ]);
      expect(run.exitCode, 0, reason: '${run.stderr}');
      expect(run.stdout, 'patched host\n');
    },
  );

  test(
    'parts and their owner move together, retaining named part-of',
    () async {
      await file(
        'package:app/main.dart',
        "import 'model.dart'; void main() => print(value());",
      );
      await file(
        'package:app/model.dart',
        "library model; part 'src/fields.dart'; part 'src/other.dart';",
      );
      await file(
        'package:app/src/fields.dart',
        "part of model; String value() => 'new';",
      );
      await file(
        'package:app/src/other.dart',
        "part of '../model.dart'; const other = 1;",
      );
      final selected = await select(['package:app/src/fields.dart']);
      expect(selected, sources.keys.toSet());
      final output = p.join(root.path, 'module');
      final remap = await remapSources(config, output, {'app'}, 9, selected);
      expect(
        File(p.join(output, 'app/src/fields.dart')).readAsStringSync(),
        startsWith('part of model;'),
      );
      expect(
        File(p.join(output, 'app/src/other.dart')).readAsStringSync(),
        startsWith("part of 'package:patch.9.app/model.dart';"),
      );
      final run = await Process.run(dartVm, [
        '--packages=${remap['packages']}',
        p.join(output, 'app/main.dart'),
      ]);
      expect(run.exitCode, 0, reason: '${run.stderr}');
      expect(run.stdout, 'new\n');
    },
  );

  test('changed dependency closes export barrels and cycles only', () async {
    await file(
      'package:app/main.dart',
      "import 'package:dep/api.dart'; void main() {}",
    );
    await file(
      'package:dep/api.dart',
      "export 'src/leaf.dart'; export 'src/stable.dart';",
    );
    await file(
      'package:dep/src/leaf.dart',
      "import '../api.dart'; String changed() => 'new';",
    );
    await file('package:dep/src/stable.dart', 'const stable = 1;');
    await file('package:dep/unused.dart', 'const unused = 2;');
    expect(await select(['package:dep/src/leaf.dart']), {
      'package:app/main.dart',
      'package:dep/api.dart',
      'package:dep/src/leaf.dart',
    });
  });

  test(
    'package fallback carries sources while excluding pinned packages',
    () async {
      await file(
        'package:app/main.dart',
        "import 'changed.dart'; void main() {}",
      );
      await file('package:app/changed.dart', "import 'package:dep/api.dart';");
      await file('package:app/unused.dart', 'void unused() {}');
      await file('package:dep/api.dart', "import 'package:host/api.dart';");
      await file('package:dep/unused.dart', 'void unused() {}');
      await file('package:host/api.dart', 'void nativeApi() {}');
      Future<Set<String>> fallback(Set<String> packages) => selectPatchSources(
        config: config,
        packages: {'app', 'dep'},
        changed: ['package:app/changed.dart'],
        baselineSources: sources.keys.toSet(),
        entry: 'package:app/main.dart',
        carryPackages: packages,
      );
      expect(await fallback({'app'}), {
        'package:app/main.dart',
        'package:app/changed.dart',
        'package:app/unused.dart',
      });
      expect(await fallback({'app', 'dep', 'host'}), {
        'package:app/main.dart',
        'package:app/changed.dart',
        'package:app/unused.dart',
        'package:dep/api.dart',
        'package:dep/unused.dart',
      });
    },
  );

  test(
    'reported part call sites include owner imports and export cycles',
    () async {
      await file('package:app/main.dart', "import 'view.dart'; void main() {}");
      await file(
        'package:app/view.dart',
        "import 'package:dep/api.dart'; part 'src/body.dart';",
      );
      await file('package:app/src/body.dart', "part of '../view.dart';");
      await file('package:dep/api.dart', "export 'src/value.dart';");
      await file(
        'package:dep/src/value.dart',
        "export '../api.dart'; String firstUse() => 'new';",
      );
      await file('package:dep/unused.dart', 'void unused() {}');
      expect(
        await selectPatchSources(
          config: config,
          packages: {'app', 'dep'},
          changed: ['package:app/src/body.dart'],
          baselineSources: sources.keys.toSet(),
          entry: 'package:app/main.dart',
          includeImportsOf: {'package:app/src/body.dart'},
        ),
        {
          'package:app/main.dart',
          'package:app/view.dart',
          'package:app/src/body.dart',
          'package:dep/api.dart',
          'package:dep/src/value.dart',
        },
      );
    },
  );

  test(
    'define changes select readers and callers while reusing other libraries',
    () async {
      await file(
        'package:app/main.dart',
        "import 'screen.dart'; import 'stable.dart'; void main() {}",
      );
      await file(
        'package:app/screen.dart',
        "import 'package:dep/config.dart'; String screen() => environment;",
      );
      await file(
        'package:dep/config.dart',
        "const environment = String.fromEnvironment('API');",
      );
      await file('package:app/stable.dart', "const label = 'API';");
      await file('package:dep/other.dart', "const value = 1;");
      final readers = await defineReaders(config, ['API']);
      expect(readers['API'], ['package:dep/config.dart']);
      final selected = await select(
        readers.values.expand((sources) => sources).toList(),
      );
      expect(selected, {
        'package:app/main.dart',
        'package:app/screen.dart',
        'package:dep/config.dart',
      });
    },
  );

  test('source hashes and imports agree on encoded library names', () async {
    await file(
      'package:app/main.dart',
      "import '页面.dart'; import 'stable.dart'; void main() {}",
    );
    await file('package:app/页面.dart', 'const value = 1;');
    await file('package:app/stable.dart', 'const stable = 2;');
    final selected = await select(['package:app/页面.dart']);
    expect(selected, {
      'package:app/main.dart',
      Uri.parse('package:app/页面.dart').toString(),
    });
    final output = p.join(root.path, 'module');
    await remapSources(config, output, {'app'}, 9, selected);
    expect(File(p.join(output, 'app/页面.dart')).existsSync(), isTrue);
    expect(File(p.join(output, 'app/stable.dart')).existsSync(), isFalse);
  });

  test(
    'newly reached sources are carried even if unchanged since release',
    () async {
      await file('package:app/main.dart', "import 'new.dart'; void main() {}");
      await file('package:app/new.dart', "export 'package:dep/new.dart';");
      await file(
        'package:dep/new.dart',
        "import 'stable.dart'; const newValue = 1;",
      );
      await file('package:dep/stable.dart', 'const stable = 1;');
      expect(
        await select(
          ['package:app/main.dart'],
          baseline: {'package:app/main.dart', 'package:dep/stable.dart'},
        ),
        {
          'package:app/main.dart',
          'package:app/new.dart',
          'package:dep/new.dart',
        },
      );
    },
  );

  test(
    'deleted sources never fall back to the baseline implementation',
    () async {
      await file(
        'package:app/main.dart',
        "import 'removed.dart'; void main() {}",
      );
      await expectLater(
        select(
          ['package:app/removed.dart'],
          baseline: {'package:app/main.dart', 'package:app/removed.dart'},
        ),
        throwsA(
          isA<Failure>().having((e) => e.code, 'code', 'PATCH_SOURCE_INVALID'),
        ),
      );
    },
  );

  test(
    'conditional directives change without touching comments or strings',
    () async {
      await file(
        'package:app/main.dart',
        "// import 'changed.dart';\nimport 'stub.dart' if (dart.library.io) 'changed.dart';\nconst text = 'changed.dart'; void main() {}",
      );
      await file('package:app/stub.dart', 'const value = 0;');
      await file('package:app/changed.dart', 'const value = 1;');
      final selected = await select(['package:app/changed.dart']);
      final output = p.join(root.path, 'module');
      await remapSources(config, output, {'app'}, 9, selected);
      final source = File(p.join(output, 'app/main.dart')).readAsStringSync();
      expect(source, contains("// import 'changed.dart';"));
      expect(source, contains("import 'package:app/stub.dart'"));
      expect(source, contains("'package:patch.9.app/changed.dart'"));
      expect(source, contains("const text = 'changed.dart';"));
    },
  );
}
