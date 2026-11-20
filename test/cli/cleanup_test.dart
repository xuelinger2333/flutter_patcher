import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:flutter_patcher/src/cli/build/outputs.dart';
import 'package:flutter_patcher/src/cli/core.dart';
import 'package:flutter_patcher/src/cli/patch/resources.dart';

class AaptFixture extends Commands {
  AaptFixture(super.cache);
  @override
  Future<String> run(
    String executable,
    List<String> args, {
    String? cwd,
    List<int>? inputBytes,
    String code = 'TOOL_FAILED',
    Duration timeout = const Duration(minutes: 15),
    Map<String, String>? extraEnvironment,
  }) async => "package: name='example.fixture' versionCode='7'";
}

void main() {
  test(
    'cache policy allows only home/project cache trees after normalization',
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
        p.join(base, '..', 'outside'),
      ]) {
        expect(() => resolve(path), throwsA(isA<Failure>()));
      }
    },
  );

  for (final bundle in [false, true]) {
    final form = bundle ? 'app bundle' : 'APK';
    test(
      'one verified $form provides matching engine, libapp and resource receipts',
      () async {
        final temp = await Directory.systemTemp.createTemp('apk-cleanup-');
        addTearDown(() => temp.delete(recursive: true));
        final apk = File(p.join(temp.path, bundle ? 'app.aab' : 'app.apk'));
        final engineBytes = [1, 2, 3],
            appBytes = [4, 5, 6],
            assetBytes = [7, 8];
        final engine = <String, dynamic>{
          'files': [
            {
              'role': 'engine',
              'contents': [
                {
                  'size': engineBytes.length,
                  'sha256': sha256.convert(engineBytes).toString(),
                },
              ],
            },
          ],
        };
        final manifest = AssetCodec.encode({
          'message.txt': [
            {'asset': 'message.txt'},
          ],
        });
        Future<void> write({
          bool wrongEngine = false,
          String? extraLibrary,
          String asset = 'message.txt',
        }) async {
          final archive = Archive();
          // An app bundle keeps an APK's files in its base module, beside
          // files of its own that never reach a device.
          final prefix = bundle ? 'base/' : '';
          void add(String name, List<int> bytes) =>
              archive.addFile(ArchiveFile('$prefix$name', bytes.length, bytes));
          add('lib/arm64-v8a/libflutter.so', wrongEngine ? [0] : engineBytes);
          add('lib/arm64-v8a/libapp.so', appBytes);
          if (extraLibrary != null) add(extraLibrary, appBytes);
          add('assets/flutter_assets/$asset', assetBytes);
          add('assets/flutter_assets/AssetManifest.bin', manifest);
          if (bundle) {
            add(
              'manifest/AndroidManifest.xml',
              protoManifest('example.fixture', '7'),
            );
            archive.addFile(ArchiveFile('BundleConfig.pb', 1, [0]));
          }
          await apk.writeAsBytes(ZipEncoder().encode(archive));
        }

        Future<Map<String, dynamic>> verify() => verifyBuildPackage(
          apk.path,
          temp.path,
          'fixture-aapt',
          AaptFixture(temp.path),
          engine,
        );
        await write();
        final receipt = await verify();
        expect(receipt['application_id'], 'example.fixture');
        expect(receipt['version_code'], '7');
        expect(receipt['apk_sha256'], await hashFile(apk.path));
        expect(
          await File(p.join(temp.path, 'libapp.so')).readAsBytes(),
          appBytes,
        );
        expect(receipt['libapp_sha256'], sha256.convert(appBytes).toString());
        expect(receipt['resources'], {
          'schema': 1,
          'files': {
            'message.txt': {
              'length': 2,
              'sha256': sha256.convert(assetBytes).toString(),
            },
            'AssetManifest.bin': {
              'length': manifest.length,
              'sha256': sha256.convert(manifest).toString(),
            },
          },
          'manifest': {
            'message.txt': [
              {'asset': 'message.txt'},
            ],
          },
        });
        for (final (scenario, code) in [
          ('wrong engine', 'ENGINE_INJECTION_FAILED'),
          ('libapp for another ABI', 'BUILD_APK_INVALID'),
          // What the Flutter Gradle plugin's ABI list puts beside the engine.
          ('a plugin library for another ABI', 'BUILD_APK_INVALID'),
          ('escaping asset', 'PATCH_ASSET_INVALID'),
        ]) {
          await write(
            wrongEngine: scenario == 'wrong engine',
            extraLibrary: switch (scenario) {
              'libapp for another ABI' => 'lib/x86_64/libapp.so',
              'a plugin library for another ABI' =>
                'lib/armeabi-v7a/libpatcher_boot.so',
              _ => null,
            },
            asset: scenario == 'escaping asset' ? '../escape' : 'message.txt',
          );
          await expectLater(
            verify(),
            throwsA(isA<Failure>().having((e) => e.code, 'code', code)),
            reason: scenario,
          );
        }
      },
    );
  }
}

/// An app bundle manifest as aapt2 writes it: an `XmlNode` protocol buffer
/// whose root `<manifest>` has [package] and `android:versionCode`.
List<int> protoManifest(String package, String versionCode) {
  List<int> varint(int value) => [
    for (; value >= 0x80; value >>= 7) (value & 0x7f) | 0x80,
    value,
  ];
  List<int> field(int number, List<int> bytes) => [
    ...varint(number << 3 | 2),
    ...varint(bytes.length),
    ...bytes,
  ];
  List<int> text(int number, String value) => field(number, utf8.encode(value));
  return field(1, [
    ...text(3, 'manifest'),
    ...field(4, [...text(2, 'package'), ...text(3, package)]),
    ...field(4, [
      ...text(1, 'http://schemas.android.com/apk/res/android'),
      ...text(2, 'versionCode'),
      ...text(3, versionCode),
      // resource_id, a varint the reader skips.
      ...varint(5 << 3),
      ...varint(0x0101021b),
    ]),
  ]);
}
