import 'dart:io';
import 'dart:convert';
import 'package:path/path.dart' as p;
import '../core.dart';
import '../patch/resources.dart';
import '../sdk/environment.dart';

Future<Map<String, dynamic>> verifyBuildApk(String apk, String baseline,
    String aapt, Commands commands, Map<String, dynamic> engine,
    {String? expectedHostTrust}) async {
  // Reuse the verified archive for libapp and resources instead of decoding three times.
  final archive = await verifyApk(apk, engine);
  final trustAssets = archive
      .where((file) => file.name == 'assets/flutter_patcher/host-trust.json')
      .toList();
  require(
      expectedHostTrust == null
          ? trustAssets.isEmpty
          : trustAssets.length == 1 &&
              utf8.decode(trustAssets.single.content) == expectedHostTrust,
      'BUILD_APK_INVALID',
      'Packaged host trust differs from explicit build policy.');
  final info = await commands.run(aapt, ['dump', 'badging', apk],
      code: 'BUILD_APK_INVALID');
  final package =
      RegExp("^package: name='([^']+)' versionCode='([0-9]+)'", multiLine: true)
          .firstMatch(info);
  require(package != null, 'BUILD_APK_INVALID',
      'Cannot read actual APK package/versionCode.');
  final libraries = archive
      .where((f) => f.name.startsWith('lib/') && f.name.endsWith('/libapp.so'))
      .toList();
  require(
      libraries.length == 1 &&
          libraries.single.name == 'lib/arm64-v8a/libapp.so',
      'BUILD_APK_INVALID',
      'Expected exactly one Android arm64 libapp.so.');
  await File(p.join(baseline, 'libapp.so'))
      .writeAsBytes(libraries.single.content);
  return {
    'application_id': package!.group(1),
    'version_code': package.group(2),
    'apk_sha256': await hashFile(apk),
    'libapp_sha256': await hashFile(p.join(baseline, 'libapp.so')),
    'resources': resourceReceipt(archive)
  };
}
