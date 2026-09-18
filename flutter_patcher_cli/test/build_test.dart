import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:flutter_patcher_cli/src/core.dart';
import 'package:flutter_patcher_cli/src/build/workspace.dart';
import 'package:flutter_patcher_cli/src/build/bootstrap.dart';
import 'package:flutter_patcher_cli/src/baseline/manifest.dart';
import 'package:flutter_patcher_cli/src/baseline/archive.dart';
import 'package:flutter_patcher_cli/src/sdk/environment.dart';
import 'baseline_test.dart' as base;

class PomDownload extends Downloads {
  final String text;
  PomDownload(this.text);
  @override
  Future<void> fetch(Uri uri, String destination,
      {String missingCode = 'ENGINE_ARTIFACT_MISSING',
      int maxBytes = 512 * 1024 * 1024}) async {
    requests++;
    expect(uri.host, 'storage.googleapis.com');
    await File(destination).writeAsString(text);
  }
}

void main() {
  test('embedding POM retains dependencies and detects damaged offline cache',
      () async {
    final root = (await Directory.systemTemp.createTemp('wp5-pom-')).path;
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
        throwsA(isA<Failure>()));
  });
  test('path dependencies and overrides are copied; originals remain intact',
      () async {
    final root = (await Directory.systemTemp.createTemp('wp5-workspace-')).path;
    for (final name in ['app', 'dep', 'override']) {
      await Directory(p.join(root, name)).create();
      await File(p.join(root, name, 'pubspec.yaml'))
          .writeAsString('name: $name\n');
    }
    await File(p.join(root, 'app/pubspec.yaml'))
        .writeAsString('name: app\ndependencies:\n  dep:\n    path: ../dep\n');
    await File(p.join(root, 'app/pubspec_overrides.yaml')).writeAsString(
        'dependency_overrides:\n  dep:\n    path: ../override\n');
    await File(p.join(root, 'app/pubspec.lock')).writeAsString(jsonEncode({
      'packages': {
        'dep': {
          'source': 'path',
          'version': '1.2.3',
          'description': {'path': '../override', 'relative': true}
        }
      },
      'sdks': {'dart': '>=3.0.0 <4.0.0'}
    }));
    final work = BuildWorkspace(p.join(root, 'copy'));
    final copy = await work.copyPackage(p.join(root, 'app'), application: true);
    for (final name in ['pubspec.yaml', 'pubspec_overrides.yaml']) {
      expect(await File(p.join(copy, name)).readAsString(),
          isNot(contains('../')));
    }
    expect(work.copies.length, 3);
    final locked =
        jsonDecode(await File(p.join(copy, 'pubspec.lock')).readAsString())
            as Map;
    expect(locked['packages']['dep']['version'], '1.2.3');
    expect(locked['packages']['dep']['description'],
        {'path': work.copies[p.join(root, 'override')], 'relative': false});
    await work.verifyOriginals();
    await File(p.join(root, 'dep/pubspec.yaml'))
        .writeAsString('name: changed\n');
    await expectLater(work.verifyOriginals(), throwsA(isA<Failure>()));
  });
  test('only tool-owned Flutter Gradle entries are retired, preserving bytes',
      () async {
    final root = (await Directory.systemTemp.createTemp('wp5-gradle-')).path;
    for (final group in ['io.flutter', 'org.example']) {
      final file =
          File(p.join(root, 'caches/modules-2/files-2.1', group, 'artifact'));
      await file.parent.create(recursive: true);
      await file.writeAsString(group);
    }
    await retireFlutterGradleCache(root);
    expect(
        await Directory(p.join(root, 'caches/modules-2/files-2.1/io.flutter'))
            .exists(),
        false);
    expect(
        await File(
                p.join(root, 'caches/modules-2/files-2.1/org.example/artifact'))
            .readAsString(),
        'org.example');
    final retired = await Directory(p.join(root, 'caches/modules-2/files-2.1'))
        .list()
        .where((f) => f.path.contains('.retired'))
        .single;
    expect(await File(p.join(retired.path, 'artifact')).readAsString(),
        'io.flutter');
  });
  test('bootstrap binds fingerprint and rejects malformed key', () {
    final source = bootstrapSource(
        'app', 'main.dart', 'a' * 64, base64Encode(List.filled(32, 1)));
    expect(source, contains('a' * 64));
    expect(source, contains('PatchBootstrap.run'));
    expect(() => bootstrapSource('app', 'main.dart', 'a' * 64, 'bad'),
        throwsA(isA<Failure>()));
  });
  test('schema 2 archive preserves compiler evidence and rejects receipt drift',
      () async {
    final root = (await Directory.systemTemp.createTemp('wp5-baseline-')).path;
    await base.fixture(root);
    final meta = {...base.metadata(), 'schema': 2, 'runtime_bootstrap': false};
    await writeObject(
        p.join(root, 'compiler_interface.json'), {'callable': <Object>[]});
    final receipt = {
      'runtime_bootstrap': false,
      'app_only': true,
      'apk_sha256': 'd' * 64,
      'interface_sha256':
          await hashFile(p.join(root, 'dynamic_interface.yaml')),
      'libapp_sha256': await hashFile(p.join(root, 'libapp.so')),
      'fingerprint': (await readObject(
          p.join(root, 'baseline.manifest.json')))['fingerprint']
    };
    await writeObject(p.join(root, 'build_receipt.json'), receipt);
    final manifest = await createManifest(root, meta);
    await writeObject(p.join(root, 'baseline.manifest.json'), manifest);
    expect((manifest['files'] as Map).length, 9);
    if (!Platform.isLinux) {
      markTestSkipped('zstd roundtrip needs a verified zstd (WP-2.6 phase B)');
    } else {
      final archive = BaselineArchive();
      await archive.pack(root, p.join(root, 'packed.tar.zst'));
      await archive.unpack(
          p.join(root, 'packed.tar.zst'), p.join(root, 'restored'));
      expect(
          (await verifyBaseline(p.join(root, 'restored')))['runtime_bootstrap'],
          false);
    }
    await writeObject(p.join(root, 'build_receipt.json'),
        {...receipt, 'fingerprint': 'e' * 64});
    await expectLater(createManifest(root, meta), throwsA(isA<Failure>()));
  });
}
