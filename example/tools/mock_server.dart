// example/tools/mock_server.dart —— 本地联调用 HTTP mock server。
// 非生产代码。只是为了让 dev 能本地 cover "checkUpdate → download → apply" 整条 HTTP 链路。
//
// 用法：
//   dart run example/tools/mock_server.dart <dist-dir> [port=8080]
//
// 前置：先用 pack 打好补丁到 <dist-dir>
//   dart run flutter_patcher:pack \
//       --apk path/to/app-release.apk \
//       --version dev-1 --target-version-code 1
//   # 产出 dist/libapp.so + dist/manifest.json
//   dart run example/tools/mock_server.dart dist 8080
//
// 暴露的两个端点（监听 0.0.0.0，手机同 Wi-Fi 可直连）：
//   GET /check       → PatchInfo JSON（version + md5 + patchUrl 自动填）
//   GET /libapp.so   → 二进制补丁字节
//
// 客户端：
//   FlutterPatcher.checkUpdate('http://<你电脑 IP>:8080/check')
//   或直接：
//   FlutterPatcher.applyPatch(PatchInfo(
//     patchUrl: 'http://<你电脑 IP>:8080/libapp.so', md5: ..., ...));

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln('usage: mock_server.dart <dist-dir> [port=8080]');
    exit(64);
  }
  final distDir = args[0];
  final port = args.length > 1 ? int.parse(args[1]) : 8080;
  final soFile = File('$distDir/libapp.so');
  if (!soFile.existsSync()) {
    stderr.writeln('not found: ${soFile.path}');
    exit(66);
  }

  final bytes = soFile.readAsBytesSync();
  final digest = md5.convert(bytes).toString();
  final server = await HttpServer.bind(InternetAddress.anyIPv4, port);
  stdout.writeln(
    '[mock] serving ${soFile.path} (${bytes.length} B, md5=$digest) on :$port',
  );

  await for (final req in server) {
    final host = req.headers.value('host') ?? 'localhost:$port';
    switch (req.uri.path) {
      case '/check':
        req.response
          ..headers.contentType = ContentType.json
          ..write(jsonEncode({
            'hasUpdate': true,
            'patch': {
              'version': 'mock-1',
              'patchUrl': 'http://$host/libapp.so',
              'md5': digest,
              'targetVersionCode': 1,
            },
          }));
        break;
      case '/libapp.so':
        req.response
          ..headers.contentType = ContentType('application', 'octet-stream')
          ..headers.contentLength = bytes.length
          ..add(bytes);
        break;
      default:
        req.response.statusCode = 404;
    }
    await req.response.close();
  }
}
