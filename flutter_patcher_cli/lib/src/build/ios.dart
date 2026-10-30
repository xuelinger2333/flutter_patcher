import 'dart:io';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import '../core.dart';
import '../patch/resources.dart';
import 'pipeline.dart';

/// Info.plist key carrying the host trust text; signed with the app, read by
/// the iOS plugin before Dart starts (Android packages the same text as an
/// APK asset).
const iosHostTrustKey = 'FlutterPatcherHostTrust';

/// `flutter build ipa --export-method` values accepted by Flutter 3.32+.
const iosExportMethods = ['app-store', 'ad-hoc', 'development', 'enterprise'];

/// Managed-SDK path of the patched device engine `flutter build ipa` embeds.
const iosEngineBinary =
    'bin/cache/artifacts/engine/ios-release/Flutter.xcframework/ios-arm64/Flutter.framework/Flutter';

Future<String?> _plistValue(Commands commands, String plist, String key) async {
  final result = await commands
      .runResult('plutil', ['-extract', key, 'raw', '-o', '-', plist]);
  return result.exitCode == 0 ? result.stdout.trimRight() : null;
}

/// Adds the host trust to the build copy's Info.plist.
Future<void> embedIosHostTrust(
    Commands commands, String project, String text) async {
  final plist = p.join(project, 'ios/Runner/Info.plist');
  await rejectLinks(plist);
  require(await File(plist).exists(), 'BUILD_CONFIG_INVALID',
      'ios/Runner/Info.plist is missing.');
  require(
      await _plistValue(commands, plist, iosHostTrustKey) == null,
      'BUILD_CONFIG_INVALID',
      'Info.plist key $iosHostTrustKey is reserved for generated build inputs.');
  await commands.run(
      'plutil', ['-insert', iosHostTrustKey, '-string', text, plist],
      code: 'BUILD_CONFIG_INVALID');
}

/// `flutter build ipa` with the managed engine; returns the exported IPA.
Future<String> assembleIpa(StepRunner run, String flutter, String project,
    BuildRequest request, String target, List<String> extra) async {
  final exported = Directory(p.join(project, 'build/ios/ipa'));
  if (await exported.exists()) await exported.delete(recursive: true);
  await run(
      flutter,
      [
        '--suppress-analytics',
        'build',
        'ipa',
        '--release',
        '--no-pub',
        '--target',
        target,
        if (request.flavor != null) ...['--flavor', request.flavor!],
        if (request.versionCode != null) ...[
          '--build-number',
          request.versionCode!
        ],
        if (request.exportMethod != null) ...[
          '--export-method',
          request.exportMethod!
        ],
        ...extra
      ],
      cwd: project);
  final ipas = await exported.exists()
      ? await exported
          .list()
          .where((entry) => entry is File && entry.path.endsWith('.ipa'))
          .toList()
      : <FileSystemEntity>[];
  require(ipas.length == 1, 'BUILD_IPA_INVALID',
      'Expected exactly one exported IPA; check signing and --export-method.');
  return ipas.single.path;
}

/// Reads the archived app back: identity, AOT snapshot (kept in [baseline]
/// as libapp.so, the baseline's name for the host AOT binary on every
/// platform), engine and resources. Receipt keys match the Android build.
Future<Map<String, dynamic>> verifyBuildIpa(Commands commands, String ipa,
    String project, String baseline, String managed,
    {required String expectedHostTrust}) async {
  final applications = Directory(p.join(
      project, 'build/ios/archive/Runner.xcarchive/Products/Applications'));
  final apps = await applications.exists()
      ? await applications
          .list()
          .where((entry) => entry is Directory && entry.path.endsWith('.app'))
          .toList()
      : <FileSystemEntity>[];
  require(apps.length == 1, 'BUILD_IPA_INVALID',
      'Expected exactly one app in the archive.');
  final app = apps.single.path;
  final plist = p.join(app, 'Info.plist');
  final id = await _plistValue(commands, plist, 'CFBundleIdentifier');
  final version = await _plistValue(commands, plist, 'CFBundleVersion');
  require(
      id != null && version != null && RegExp(r'^[0-9]+$').hasMatch(version),
      'BUILD_IPA_INVALID',
      'The app needs a bundle identifier and an integer CFBundleVersion.');
  require(
      await _plistValue(commands, plist, iosHostTrustKey) == expectedHostTrust,
      'BUILD_IPA_INVALID',
      'Packaged host trust differs from explicit build policy.');
  final engine = await File(p.join(app, 'Frameworks/Flutter.framework/Flutter'))
      .readAsBytes();
  final expected =
      machoUuid(await File(p.join(managed, iosEngineBinary)).readAsBytes());
  require(
      expected != null && _same(machoUuid(engine), expected),
      'ENGINE_INJECTION_FAILED',
      'The app does not embed the patched iOS engine.');
  final aot = File(p.join(app, 'Frameworks/App.framework/App'));
  require(await aot.exists() && machoUuid(await aot.readAsBytes()) != null,
      'BUILD_IPA_INVALID', 'Expected an arm64 App.framework AOT snapshot.');
  await aot.copy(p.join(baseline, 'libapp.so'));
  return {
    'application_id': id,
    'version_code': version,
    'apk_sha256': await hashFile(ipa),
    'libapp_sha256': await hashFile(p.join(baseline, 'libapp.so')),
    'resources': resourceReceipt(await flutterAssetsArchive(
        p.join(app, 'Frameworks/App.framework/flutter_assets')))
  };
}

bool _same(List<int>? a, List<int> b) =>
    a != null && a.length == b.length && a.join(',') == b.join(',');

/// LC_UUID of a thin arm64 Mach-O; code signing leaves it unchanged, so it
/// identifies the engine Xcode embedded and re-signed.
List<int>? machoUuid(List<int> bytes) {
  if (bytes.length < 32 ||
      bytes.take(8).join(',') != '207,250,237,254,12,0,0,1') {
    return null;
  }
  final data =
      ByteData.sublistView(Uint8List.fromList(bytes.take(1 << 20).toList()));
  final count = data.getUint32(16, Endian.little);
  var offset = 32;
  for (var i = 0; i < count && offset + 8 <= data.lengthInBytes; i++) {
    final command = data.getUint32(offset, Endian.little);
    final size = data.getUint32(offset + 4, Endian.little);
    if (command == 0x1b && offset + 24 <= data.lengthInBytes) {
      return bytes.sublist(offset + 8, offset + 24);
    }
    if (size < 8) return null;
    offset += size;
  }
  return null;
}

/// The app's flutter_assets in the APK layout resourceReceipt reads.
Future<Archive> flutterAssetsArchive(String directory) async {
  final archive = Archive();
  await for (final entry
      in Directory(directory).list(recursive: true, followLinks: false)) {
    require(entry is! Link, 'BUILD_IPA_INVALID',
        'flutter_assets cannot contain links: ${entry.path}');
    if (entry is! File) continue;
    final key =
        p.posix.joinAll(p.split(p.relative(entry.path, from: directory)));
    final bytes = await entry.readAsBytes();
    archive.addFile(
        ArchiveFile('assets/flutter_assets/$key', bytes.length, bytes));
  }
  return archive;
}
