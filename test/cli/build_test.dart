import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:flutter_patcher/src/cli/core.dart';
import 'package:flutter_patcher/src/cli/build/pipeline.dart';
import 'package:flutter_patcher/src/cli/build/workspace.dart';
import 'package:flutter_patcher/src/cli/build/bootstrap.dart';
import 'package:flutter_patcher/src/cli/baseline/manifest.dart';
import 'package:flutter_patcher/src/cli/baseline/archive.dart';
import 'package:flutter_patcher/src/cli/sdk/environment.dart';

import 'baseline_test.dart' as base;

class PomDownload extends Downloads {
  final String text;
  PomDownload(this.text);
  @override
  Future<void> fetch(
    Uri uri,
    String destination, {
    String missingCode = 'ENGINE_ARTIFACT_MISSING',
    int maxBytes = 512 * 1024 * 1024,
  }) async {
    requests++;
    expect(uri.host, 'storage.googleapis.com');
    await File(destination).writeAsString(text);
  }
}

void main() {
  test('embedding POM retains dependencies and detects damaged offline cache', () async {
    final root = (await Directory.systemTemp.createTemp('build-pom-')).path;
    final path = p.join(root, 'embedding.pom');
    const pom =
        '<project><groupId>io.flutter</groupId><artifactId>flutter_embedding_release</artifactId>'
        '<version>1.0.0-test</version><dependencies><dependency>upstream</dependency></dependencies></project>';
    final download = PomDownload(pom);
    await embeddingPom(path, '1.0.0-test', download);
    expect(await File(path).readAsString(), pom);
    await embeddingPom(path, '1.0.0-test', Downloads(offline: true));
    expect(download.requests, 1);
    await File(path).writeAsString('$pom ');
    await expectLater(
      embeddingPom(path, '1.0.0-test', Downloads(offline: true)),
      throwsA(isA<Failure>()),
    );
  });
  test(
    'path dependencies and overrides are copied; originals remain intact',
    () async {
      final root = (await Directory.systemTemp.createTemp('build-workspace-'))
          .path;
      for (final name in ['app', 'dep', 'override']) {
        await Directory(p.join(root, name)).create();
        await File(p.join(root, name, 'pubspec.yaml'))
            .writeAsString('name: $name\n');
      }
      await File(
        p.join(root, 'app/pubspec.yaml'),
      ).writeAsString('name: app\ndependencies:\n  dep:\n    path: ../dep\n');
      await Directory(p.join(root, 'dep/example/build'))
          .create(recursive: true);
      await File(p.join(root, 'dep/example/pubspec.yaml'))
          .writeAsString('name: example\n');
      await File(
        p.join(root, 'app/pubspec_overrides.yaml'),
      ).writeAsString('dependency_overrides:\n  dep:\n    path: ../override\n');
      await File(p.join(root, 'app/pubspec.lock')).writeAsString(
        jsonEncode({
          'packages': {
            'dep': {
              'source': 'path',
              'version': '1.2.3',
              'description': {'path': '../override', 'relative': true},
            },
          },
          'sdks': {'dart': '>=3.0.0 <4.0.0'},
        }),
      );
      final work = BuildWorkspace(p.join(root, 'copy'));
      final copy = await work.copyPackage(
        p.join(root, 'app'),
        application: true,
      );
      for (final name in ['pubspec.yaml', 'pubspec_overrides.yaml']) {
        expect(
          await File(p.join(copy, name)).readAsString(),
          isNot(contains('../')),
        );
      }
      expect(work.copies.length, 3);
      // The dependency's example app is not part of the dependency.
      expect(
        await Directory(p.join(work.copies[p.join(root, 'dep')]!, 'example'))
            .exists(),
        false,
      );
      final locked = jsonDecode(
        await File(p.join(copy, 'pubspec.lock')).readAsString(),
      ) as Map;
      expect(locked['packages']['dep']['version'], '1.2.3');
      expect(locked['packages']['dep']['description'], {
        'path': work.copies[p.join(root, 'override')],
        'relative': false,
      });
      await work.verifyOriginals();
      await File(p.join(root, 'dep/pubspec.yaml'))
          .writeAsString('name: changed\n');
      await expectLater(work.verifyOriginals(), throwsA(isA<Failure>()));
    },
  );
  test('every Android build runs flutter_patcher\'s init script', () async {
    final home = (await Directory.systemTemp.createTemp('build-gradle-')).path;
    addTearDown(() => Directory(home).delete(recursive: true));
    final script = File(p.join(home, 'init.d', 'flutter_patcher.gradle'));
    await installInitScript(home);
    expect(await script.readAsString(), initScript);
    expect(initScript, contains("abiFilters.add('arm64-v8a')"));
    expect(initScript, contains("getenv('FLUTTER_PATCHER_ENGINE_SYMBOLS')"));
    expect(
      initScript,
      contains("'com.android.tools.build.debugsymbols/arm64-v8a'"),
    );
    // An older flutter_patcher's script gives way to this one's.
    await script.writeAsString('// stale');
    await installInitScript(home);
    expect(await script.readAsString(), initScript);
    expect(await script.parent.list().length, 1);
  });
  test('a build that cannot subset icon fonts says where, and what to use', () {
    const output = '''
Running Gradle task 'assembleRelease'...
This application cannot tree shake icons fonts. It has non-constant instances of IconData at the following locations:
  - lib/main.dart:12:20
  - dependencies/2/lib/a.dart:203:19
  - lib/b.dart:1
  - lib/c.dart:2
Target aot_android_asset_bundle failed
BUILD FAILED in 1m 27s
''';
    final failure = dynamicIconFailure(output, evidence: 'work')!;
    expect(failure.code, 'BUILD_STEP_FAILED');
    expect(
      failure.message,
      allOf(
        contains(
          'lib/main.dart:12:20, dependencies/2/lib/a.dart:203:19, '
          'lib/b.dart:1 and 1 more',
        ),
        contains('--no-tree-shake-icons'),
        contains('Evidence: work'),
      ),
    );
    expect(dynamicIconFailure('BUILD FAILED', evidence: 'work'), isNull);
    // flutter_tools names the project copy's files by URI.
    final copy = p.join(Directory.systemTemp.path, 'copy');
    final uri = p.toUri(p.join(copy, 'lib', 'main.dart'));
    expect(
      dynamicIconFailure(
        'cannot tree shake icons fonts. At:\n - $uri:12:20\n',
        evidence: 'work',
        project: copy,
      )!.message,
      contains('(lib/main.dart:12:20)'),
    );
  });
  test(
    'an app bundle\'s engine symbols are the engine jar\'s library',
    () async {
      final root = (await Directory.systemTemp.createTemp('build-symbols-'))
          .path;
      addTearDown(() => Directory(root).delete(recursive: true));
      final library = utf8.encode('stripped libflutter.so');
      final jar = File(p.join(root, 'engine.jar'));
      await jar.writeAsBytes(
        ZipEncoder().encodeBytes(
          Archive()..addFile(
            ArchiveFile.bytes('lib/arm64-v8a/libflutter.so', library),
          ),
        ),
      );
      final path = await writeEngineSymbols(jar.path, p.join(root, 'out'));
      expect(p.basename(path), 'libflutter.so.sym');
      expect(await File(path).readAsBytes(), library);
      await jar.writeAsBytes(ZipEncoder().encodeBytes(Archive()));
      await expectLater(
        writeEngineSymbols(jar.path, p.join(root, 'out')),
        throwsA(isA<Failure>()),
      );
    },
  );
  test(
    'only tool-owned Flutter Gradle entries are retired, preserving bytes',
    () async {
      final root = (await Directory.systemTemp.createTemp('build-gradle-'))
          .path;
      for (final group in ['io.flutter', 'org.example']) {
        final file = File(
          p.join(root, 'caches/modules-2/files-2.1', group, 'artifact'),
        );
        await file.parent.create(recursive: true);
        await file.writeAsString(group);
      }
      await retireFlutterGradleCache(root);
      expect(
        await Directory(p.join(root, 'caches/modules-2/files-2.1/io.flutter'))
            .exists(),
        false,
      );
      expect(
        await File(
          p.join(root, 'caches/modules-2/files-2.1/org.example/artifact'),
        ).readAsString(),
        'org.example',
      );
      final retired = await Directory(
        p.join(root, 'caches/modules-2/files-2.1'),
      ).list().where((f) => f.path.contains('.retired')).single;
      expect(
        await File(p.join(retired.path, 'artifact')).readAsString(),
        'io.flutter',
      );
    },
  );
  test('bootstrap binds fingerprint', () {
    final source = bootstrapSource(
      'app',
      'main.dart',
      'a' * 64,
      base64Encode(List.filled(32, 1)),
    );
    expect(source, contains('a' * 64));
    expect(source, contains('PatchBootstrap.run'));
  });
  test('bootstrap declares the entry hook for both strategies', () {
    final key = base64Encode(List.filled(32, 1));
    for (final modules in [true, false]) {
      final source = bootstrapSource(
        'app',
        'main.dart',
        'a' * 64,
        key,
        modules: modules,
      );
      expect(
        source,
        contains('const flutterPatcherAppLibrary = "package:app/main.dart";'),
      );
      expect(
        source,
        contains(
          'Function? flutterPatcherEntry(String key, '
          'Function? original, bool start) =>',
        ),
      );
      expect(source, contains('PatchBootstrap.entry(key, original'));
      // Both the main and the hook load modules only on a bytecode host.
      expect(
        'loadModule: loadModule'.allMatches(source).length,
        modules ? 2 : 0,
      );
    }
  });
  test(
    'schema 2 archive preserves compiler evidence and rejects receipt drift',
    () async {
      final root = (await Directory.systemTemp.createTemp('build-baseline-'))
          .path;
      await base.fixture(root);
      final meta = {
        ...base.metadata(),
        'schema': 2,
        'runtime_bootstrap': false,
      };
      await writeObject(p.join(root, 'compiler_interface.json'), {
        'callable': <Object>[],
      });
      final receipt = {
        'runtime_bootstrap': false,
        'app_only': true,
        'apk_sha256': 'd' * 64,
        'interface_sha256': await hashFile(
          p.join(root, 'dynamic_interface.yaml'),
        ),
        'libapp_sha256': await hashFile(p.join(root, 'libapp.so')),
        'fingerprint': (await readObject(
          p.join(root, 'baseline.manifest.json'),
        ))['fingerprint'],
      };
      await writeObject(p.join(root, 'build_receipt.json'), receipt);
      final manifest = await createManifest(root, meta);
      await writeObject(p.join(root, 'baseline.manifest.json'), manifest);
      expect((manifest['files'] as Map).length, 9);
      final archive = BaselineArchive();
      await archive.pack(root, p.join(root, 'packed.tar.gz'));
      await archive.unpack(
        p.join(root, 'packed.tar.gz'),
        p.join(root, 'restored'),
      );
      expect(
        (await verifyBaseline(p.join(root, 'restored')))['runtime_bootstrap'],
        false,
      );
      await writeObject(p.join(root, 'build_receipt.json'), {
        ...receipt,
        'fingerprint': 'e' * 64,
      });
      await expectLater(createManifest(root, meta), throwsA(isA<Failure>()));
    },
  );
}
