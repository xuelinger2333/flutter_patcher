import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import '../bin/pack.dart' as pack;

void main() {
  test('pack writes libapp.so and manifest.json', () async {
    final temp = await Directory.systemTemp.createTemp('flutter_patcher_pack_');
    addTearDown(() async {
      if (await temp.exists()) {
        await temp.delete(recursive: true);
      }
    });

    final apk = File('${temp.path}/app-release.apk');
    final soBytes = utf8.encode('fake libapp.so bytes');
    final archive = Archive()
      ..addFile(ArchiveFile('lib/arm64-v8a/libapp.so', soBytes.length, soBytes));
    await apk.writeAsBytes(ZipEncoder().encode(archive)!);

    final outDir = Directory('${temp.path}/dist');
    final exitCode = await pack.main([
      '--apk',
      apk.path,
      '--version',
      '1.0.0-h1',
      '--target-version-code',
      '100',
      '--out',
      outDir.path,
    ]);

    expect(exitCode, 0);
    expect(await File('${outDir.path}/libapp.so').readAsBytes(), soBytes);

    final manifest = jsonDecode(
      await File('${outDir.path}/manifest.json').readAsString(),
    ) as Map<String, dynamic>;
    expect(manifest['version'], '1.0.0-h1');
    expect(manifest['targetVersionCode'], 100);
    expect(manifest['abi'], 'arm64-v8a');
    expect(manifest['md5'], md5.convert(soBytes).toString());
  });
}
