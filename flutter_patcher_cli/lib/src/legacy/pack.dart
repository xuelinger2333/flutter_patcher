import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:args/args.dart';
import 'package:crypto/crypto.dart';
import '../core.dart';
import '../patch/resources.dart';
import '../patch/so_package.dart';

// `flutter_patcher pack`: the v1 SO packer for hosts without a host policy,
// with the options and exit codes of the former `dart run flutter_patcher:pack`.
const _abiPriority = ['arm64-v8a', 'armeabi-v7a', 'x86_64'];

class PackException implements Exception {
  const PackException(this.message, this.exitCode);
  final String message;
  final int exitCode;
}

Future<int> packMain(List<String> argv) async {
  final parser = ArgParser()
    ..addOption('apk', abbr: 'a', help: 'Release APK to extract libapp.so and assets from.')
    ..addMultiOption('assets',
        help: 'Asset key(s) to include; repeat, comma-separate or use @list.txt '
            '(one per line, # comments).')
    ..addOption('version', help: 'Patch version string (manifest.version).')
    ..addOption('target-version-code', help: 'Host APK versionCode (integer).')
    ..addOption('abi', help: 'ABI to extract. Default: first of $_abiPriority.')
    ..addOption('out', abbr: 'o', help: 'Output directory.', defaultsTo: 'dist')
    ..addFlag('help', abbr: 'h', negatable: false);
  try {
    final args = parser.parse(argv);
    if (args['help'] == true) {
      stdout.writeln('usage: flutter_patcher pack [options]\n\n${parser.usage}');
      return 0;
    }
    final apkPath = args['apk'] as String?, version = args['version'] as String?;
    final vc = int.tryParse(args['target-version-code'] as String? ?? '');
    if (apkPath == null || version == null || vc == null) {
      throw PackException('--apk, --version and an integer --target-version-code are required.\n${parser.usage}', 64);
    }
    final keys = readRequestedAssets(args['assets'] as List<String>);
    if (!File(apkPath).existsSync()) throw PackException('APK not found: $apkPath', 66);
    final apk = ZipDecoder().decodeBytes(File(apkPath).readAsBytesSync());
    final abi = [args['abi'] as String?, ..._abiPriority].whereType<String>().firstWhere(
        (a) => apk.findFile('lib/$a/libapp.so') != null,
        orElse: () => throw const PackException('libapp.so not found in APK.', 1));
    final files = <String, List<int>>{}, upserts = <String, Object?>{};
    var baseManifestSize = 0;
    if (keys.isNotEmpty) {
      final entry = apk.findFile('assets/flutter_assets/AssetManifest.bin');
      if (entry == null) throw const PackException('AssetManifest.bin not found in APK.', 65);
      final bytes = entry.content as List<int>;
      baseManifestSize = bytes.length;
      final Map<String, dynamic> manifest;
      try {
        manifest = AssetCodec.decode(bytes);
      } on Failure catch (e) {
        throw PackException(e.message, 65);
      }
      for (final key in keys) {
        final variants = manifest[key];
        if (variants is! List) throw PackException('asset key not found in AssetManifest.bin: $key', 65);
        upserts[key] = variants;
        for (final variant in variants.cast<Map>()) {
          final path = variant['asset'];
          if (path is! String || !_safe(path)) throw PackException('invalid variant asset for key $key', 65);
          final file = apk.findFile('assets/flutter_assets/$path');
          if (file == null) throw PackException('variant file for $key not found in APK: $path', 65);
          files[path] = file.content as List<int>;
        }
      }
    }
    final package = v2Package(
        libapp: apk.findFile('lib/$abi/libapp.so')!.content as List<int>,
        abi: abi,
        files: files,
        upserts: upserts,
        baseManifestSize: baseManifestSize,
        version: version,
        targetVersionCode: vc);
    final out = Directory(args['out'] as String)..createSync(recursive: true);
    File('${out.path}/patch.zip').writeAsBytesSync(package);
    final md5Hex = md5.convert(package).toString();
    File('${out.path}/manifest.json').writeAsStringSync('${const JsonEncoder.withIndent('  ').convert({
      'schemaVersion': 2,
      'version': version,
      'md5': md5Hex,
      'targetVersionCode': vc,
      'abi': abi,
      'payload': 'patch.zip',
    })}\n');
    stdout.writeln('[pack] payload: ${out.path}/patch.zip (abi=$abi, assets=${keys.length}, md5=$md5Hex)');
    return 0;
  } on FormatException catch (e) {
    stderr.writeln('error: ${e.message}\n${parser.usage}');
    return 64;
  } on PackException catch (e) {
    stderr.writeln('error: ${e.message}');
    return e.exitCode;
  }
}

bool _safe(String path) =>
    path.isNotEmpty && !path.startsWith('/') && !path.split('/').any((s) => s == '..' || s.isEmpty);

/// Asset keys from repeated/comma-separated `--assets`; `@file` reads one key
/// per line with `#` comments. Nested `@` inside a list file is rejected.
List<String> readRequestedAssets(List<String> values) {
  final result = <String>[];
  void add(String raw, String source) {
    final key = raw.trim().replaceAll('\\', '/');
    if (key.isEmpty || key.startsWith('#')) return;
    if (key.startsWith('@')) throw PackException('nested @-includes are not supported inside $source.', 65);
    if (!_safe(key)) throw PackException('invalid asset key: $key', 65);
    if (!result.contains(key)) result.add(key);
  }
  for (final token in values.expand((v) => v.split(',')).map((t) => t.trim())) {
    if (!token.startsWith('@')) {
      add(token, '--assets');
      continue;
    }
    final file = File(token.substring(1));
    if (token.length == 1) throw const PackException('"@" must be followed by a file path.', 64);
    if (!file.existsSync()) throw PackException('asset list file not found: ${file.path}', 66);
    for (final line in file.readAsLinesSync()) {
      add(line, file.path);
    }
  }
  return result;
}