// `dart run flutter_patcher:pack` —— 从 release APK 打出一个可下发的 Dart 补丁包。
//
// 做的事：
//   * 从 APK 按 ABI 提取 `lib/<abi>/libapp.so`
//   * 计算 MD5
//   * 生成 manifest.json（不含 patchUrl —— 那是后端属性）
//
// 用法示例见 `--help` 输出。

import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:args/args.dart';
import 'package:crypto/crypto.dart';

/// ABI 优先级：没显式传 --abi 时按此顺序在 APK 里找第一个有的。
const _abiPriority = <String>['arm64-v8a', 'armeabi-v7a', 'x86_64'];

Future<int> main(List<String> argv) async {
  final parser = ArgParser()
    ..addOption(
      'apk',
      abbr: 'a',
      help: 'Path to the release APK to extract libapp.so from.',
    )
    ..addOption(
      'version',
      help: 'Patch version string (goes into manifest.version).',
    )
    ..addOption(
      'target-version-code',
      help:
          'Host APK versionCode the patch is built for (integer). '
          'Runtime will reject the patch if it doesn\'t match.',
    )
    ..addOption(
      'abi',
      help: 'ABI to extract. Default: first match among $_abiPriority.',
    )
    ..addOption(
      'out',
      abbr: 'o',
      help: 'Output directory. Created if absent.',
      defaultsTo: 'dist',
    )
    ..addFlag('help', abbr: 'h', negatable: false, help: 'Show help.');

  final ArgResults args;
  try {
    args = parser.parse(argv);
  } on FormatException catch (e) {
    stderr.writeln('error: ${e.message}');
    stderr.writeln(parser.usage);
    return 64; // EX_USAGE
  }

  if (args['help'] as bool) {
    stdout.writeln('flutter_patcher pack CLI\n');
    stdout.writeln('usage: dart run flutter_patcher:pack [options]\n');
    stdout.writeln(parser.usage);
    return 0;
  }

  // ---- required args ----
  final apkPath = args['apk'] as String?;
  final version = args['version'] as String?;
  final vcRaw = args['target-version-code'] as String?;
  if (apkPath == null || version == null || vcRaw == null) {
    stderr.writeln(
      'error: --apk, --version, --target-version-code are required.',
    );
    stderr.writeln(parser.usage);
    return 64;
  }
  final targetVersionCode = int.tryParse(vcRaw);
  if (targetVersionCode == null) {
    stderr.writeln('error: --target-version-code must be an integer.');
    return 64;
  }

  // ---- optional args ----
  final preferredAbi = args['abi'] as String?;
  final outDir = Directory(args['out'] as String);

  // ---- read APK ----
  final apkFile = File(apkPath);
  if (!apkFile.existsSync()) {
    stderr.writeln('error: APK not found: $apkPath');
    return 66; // EX_NOINPUT
  }
  stdout.writeln('[pack] reading ${apkFile.path}');
  final apkBytes = apkFile.readAsBytesSync();
  final archive = ZipDecoder().decodeBytes(apkBytes);

  // ---- pick ABI ----
  final chosen = _pickLibappSo(archive, preferredAbi);
  if (chosen == null) {
    stderr.writeln(
      'error: libapp.so not found in APK for any of $_abiPriority '
      '(or requested --abi $preferredAbi).',
    );
    return 1;
  }
  final abi = chosen.$1;
  final entry = chosen.$2;
  final soBytes = entry.content as List<int>;
  stdout.writeln(
    '[pack] extracted lib/$abi/libapp.so (${_fmtBytes(soBytes.length)})',
  );

  // ---- write output .so ----
  outDir.createSync(recursive: true);
  final outSoPath = '${outDir.path}/libapp.so';
  File(outSoPath).writeAsBytesSync(soBytes);

  // ---- compute md5 ----
  final md5Digest = md5.convert(soBytes).toString();
  stdout.writeln('[pack] md5: $md5Digest');

  // ---- write manifest ----
  // 不含 patchUrl：那是服务端属性（补丁上传 CDN 后才知道），由后端在返回补丁
  // 响应时自行填入，不属于打包产物。
  final manifest = <String, dynamic>{
    'version': version,
    'md5': md5Digest,
    'targetVersionCode': targetVersionCode,
    'abi': abi,
    'mode': 'full',
  };
  final manifestPath = '${outDir.path}/manifest.json';
  File(manifestPath).writeAsStringSync(
    '${const JsonEncoder.withIndent('  ').convert(manifest)}\n',
  );
  stdout.writeln('[pack] manifest: $manifestPath');
  stdout.writeln(
    '[pack] version=$version, targetVersionCode=$targetVersionCode, abi=$abi',
  );

  return 0;
}

/// 在 APK 里找 `lib/<abi>/libapp.so`。
/// - 若传了 [preferred] 且存在，用它
/// - 否则按 [_abiPriority] 顺序取第一个
/// 返回 (abi, entry)；没找到返回 null。
(String, ArchiveFile)? _pickLibappSo(Archive archive, String? preferred) {
  final map = <String, ArchiveFile>{};
  final regex = RegExp(r'^lib/([^/]+)/libapp\.so$');
  for (final file in archive.files) {
    final m = regex.firstMatch(file.name);
    if (m != null) map[m.group(1)!] = file;
  }
  if (preferred != null) {
    final hit = map[preferred];
    if (hit != null) return (preferred, hit);
    stderr.writeln('warning: --abi $preferred not in APK; falling back');
  }
  for (final abi in _abiPriority) {
    final hit = map[abi];
    if (hit != null) return (abi, hit);
  }
  return null;
}

String _fmtBytes(int n) {
  if (n < 1024) return '$n B';
  if (n < 1024 * 1024) return '${(n / 1024).toStringAsFixed(1)} KB';
  return '${(n / 1024 / 1024).toStringAsFixed(2)} MB';
}
