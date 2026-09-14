import 'dart:io';
import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:flutter_patcher_cli/src/build/outputs.dart';
import 'package:flutter_patcher_cli/src/core.dart';
import 'package:flutter_patcher_cli/src/patch/resources.dart';

class AaptFixture extends Commands {
  AaptFixture(super.cache);
  @override
  Future<String> run(String executable, List<String> args,
          {String? cwd,
          List<int>? inputBytes,
          String code = 'TOOL_FAILED',
          Duration timeout = const Duration(minutes: 15),
          Map<String, String>? extraEnvironment}) async =>
      "package: name='example.fixture' versionCode='7'";
}

void main() {
  test('cache policy allows only home/project cache trees after normalization',
      () {
    final home = p.absolute('fixture-home'),
        project = p.absolute('fixture-project');
    String resolve(String? value) =>
        managedCache(value, home: home, project: project);
    final base = p.join(home, '.flutter_patcher');
    expect(resolve(null), base);
    expect(resolve(p.join(base, 'build')), p.join(base, 'build'));
    final local = p.join(project, '.dart_tool', 'flutter_patcher');
    expect(resolve(local), local);
    for (final path in [
      home,
      project,
      '$base-other',
      p.join(base, '..', 'outside')
    ]) {
      expect(() => resolve(path), throwsA(isA<Failure>()));
    }
  });

  test(
      'one verified APK provides matching engine, libapp and resource receipts',
      () async {
    final temp = await Directory.systemTemp.createTemp('apk-cleanup-');
    addTearDown(() => temp.delete(recursive: true));
    final apk = File(p.join(temp.path, 'app.apk'));
    final engineBytes = [1, 2, 3], appBytes = [4, 5, 6], assetBytes = [7, 8];
    final engine = <String, dynamic>{
      'files': [
        {
          'role': 'engine',
          'contents': [
            {
              'size': engineBytes.length,
              'sha256': sha256.convert(engineBytes).toString()
            }
          ]
        }
      ]
    };
    final manifest = AssetCodec.encode({
      'message.txt': [
        {'asset': 'message.txt'}
      ]
    });
    Future<void> write(
        {bool wrongEngine = false,
        bool extraAbi = false,
        String asset = 'message.txt'}) async {
      final archive = Archive();
      void add(String name, List<int> bytes) =>
          archive.addFile(ArchiveFile(name, bytes.length, bytes));
      add('lib/arm64-v8a/libflutter.so', wrongEngine ? [0] : engineBytes);
      add('lib/arm64-v8a/libapp.so', appBytes);
      if (extraAbi) add('lib/x86_64/libapp.so', appBytes);
      add('assets/flutter_assets/$asset', assetBytes);
      add('assets/flutter_assets/AssetManifest.bin', manifest);
      await apk.writeAsBytes(ZipEncoder().encode(archive));
    }

    Future<Map<String, dynamic>> verify() => verifyBuildApk(
        apk.path, temp.path, 'fixture-aapt', AaptFixture(temp.path), engine);
    await write();
    final receipt = await verify();
    expect(receipt['application_id'], 'example.fixture');
    expect(receipt['version_code'], '7');
    expect(receipt['apk_sha256'], await hashFile(apk.path));
    expect(await File(p.join(temp.path, 'libapp.so')).readAsBytes(), appBytes);
    expect(receipt['libapp_sha256'], sha256.convert(appBytes).toString());
    expect(receipt['resources'], {
      'schema': 1,
      'files': {
        'message.txt': {
          'length': 2,
          'sha256': sha256.convert(assetBytes).toString()
        },
        'AssetManifest.bin': {
          'length': manifest.length,
          'sha256': sha256.convert(manifest).toString()
        }
      },
      'manifest': {
        'message.txt': [
          {'asset': 'message.txt'}
        ]
      }
    });
    for (final scenario in [0, 1, 2]) {
      await write(
          wrongEngine: scenario == 0,
          extraAbi: scenario == 1,
          asset: scenario == 2 ? '../escape' : 'message.txt');
      await expectLater(
          verify(),
          throwsA(isA<Failure>().having(
              (e) => e.code,
              'code',
              [
                'ENGINE_INJECTION_FAILED',
                'BUILD_APK_INVALID',
                'PATCH_ASSET_INVALID'
              ][scenario])));
    }
  });
}
