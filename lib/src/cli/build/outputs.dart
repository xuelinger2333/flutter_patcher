import 'dart:io';
import 'dart:convert';

import 'package:path/path.dart' as p;

import '../core.dart';
import '../patch/resources.dart';
import '../sdk/android.dart';
import '../sdk/android_manifest.dart';
import '../sdk/environment.dart';

/// Checks the Android package at [path] (an APK or an app bundle) that a
/// build or an SO patch made: the engine, the packaged host trust, arm64-v8a
/// native code only, and the app identity. Extracts its libapp.so into
/// [baseline] and returns the receipt both forms share.
Future<Map<String, dynamic>> verifyBuildPackage(
  String path,
  String baseline,
  String aapt,
  Commands commands,
  Map<String, dynamic> engine, {
  String? expectedHostTrust,
}) async {
  const code = 'BUILD_APK_INVALID';
  final package = AndroidPackage.of(path);
  // Reuse the verified archive for libapp and resources instead of decoding three times.
  final archive = await verifyAndroidEngine(path, engine);
  final trustAssets = archive
      .where((file) => file.name == 'assets/flutter_patcher/host-trust.json')
      .toList();
  require(
    expectedHostTrust == null
        ? trustAssets.isEmpty
        : trustAssets.length == 1 &&
              utf8.decode(trustAssets.single.content) == expectedHostTrust,
    code,
    'Packaged host trust differs from explicit build policy.',
  );
  // A device installs native code for its ABI only when the package has
  // the engine for that ABI too; a host has it for arm64-v8a only.
  final foreign = [
    for (final file in archive)
      if (file.isFile &&
          file.name.startsWith('lib/') &&
          !file.name.startsWith('lib/arm64-v8a/'))
        file.name,
  ]..sort();
  require(
    foreign.isEmpty,
    code,
    'The ${package.noun} has native code for other ABIs than arm64-v8a, '
    'the only one a host runs on: ${foreign.take(5).join(', ')}'
    '${foreign.length > 5 ? ' and ${foreign.length - 5} more' : ''}.',
  );
  final (id, versionCode) = await _identity(path, archive, aapt, commands);
  final libraries = archive
      .where((f) => f.name.startsWith('lib/') && f.name.endsWith('/libapp.so'))
      .toList();
  require(
    libraries.length == 1 && libraries.single.name == 'lib/arm64-v8a/libapp.so',
    code,
    'Expected exactly one Android arm64 libapp.so.',
  );
  await File(p.join(baseline, 'libapp.so'))
      .writeAsBytes(libraries.single.content);
  return {
    'application_id': id,
    'version_code': versionCode,
    'apk_sha256': await hashFile(path),
    'libapp_sha256': await hashFile(p.join(baseline, 'libapp.so')),
    'resources': resourceReceipt(archive),
  };
}

/// The application id and versionCode the package at [path] declares.
/// `aapt dump badging` reads an APK's binary XML manifest; an app bundle's
/// is a protocol buffer it cannot read.
Future<(String, String)> _identity(
  String path,
  Iterable<dynamic> archive,
  String aapt,
  Commands commands,
) async {
  const code = 'BUILD_APK_INVALID';
  final package = AndroidPackage.of(path);
  final String? id, versionCode;
  if (package == AndroidPackage.apk) {
    final info = await commands.run(aapt, [
      'dump',
      'badging',
      path,
    ], code: code);
    final match = RegExp(
      "^package: name='([^']+)' versionCode='([0-9]+)'",
      multiLine: true,
    ).firstMatch(info);
    id = match?.group(1);
    versionCode = match?.group(2);
  } else {
    final manifests = [
      for (final file in archive)
        if (file.name == 'manifest/AndroidManifest.xml') file,
    ];
    final attributes = manifests.length == 1
        ? manifestAttributes(manifests.single.content as List<int>)
        : const <String, String>{};
    id = attributes['package'];
    versionCode = attributes['versionCode'];
  }
  require(
    id != null &&
        id.isNotEmpty &&
        versionCode != null &&
        RegExp(r'^[0-9]+$').hasMatch(versionCode),
    code,
    'Cannot read the ${package.noun}\'s package and versionCode.',
  );
  return (id!, versionCode!);
}
