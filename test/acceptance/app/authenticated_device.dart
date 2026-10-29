// Device fixture for authenticated hosts (SO or bytecode). Test-only trust: the
// CA is accepted by this app alone, via HttpOverrides and its native NSC.
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_patcher/flutter_patcher.dart';

const revision = 'original';
const testCa = r"""__TEST_CA__""";

class _TestTrust extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      super.createHttpClient(SecurityContext(withTrustedRoots: true)
        ..setTrustedCertificatesBytes(utf8.encode(testCa)));
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = _TestTrust();
  await FlutterPatcher.init();
  final asset = await rootBundle.loadString('assets/msg.txt');
  runApp(MaterialApp(
      home: Scaffold(body: Center(child: Text('revision: $revision\n$asset')))));
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 8767);
  server.listen((request) async {
    request.response.headers.contentType = ContentType.json;
    try {
      final body = request.method == 'POST'
          ? jsonDecode(await utf8.decoder.bind(request).join()) as Map
          : const {};
      Object? out;
      switch (request.uri.path) {
        case '/status':
          out = {
            'revision': revision,
            'asset': asset,
            'version': await FlutterPatcher.currentVersion,
            'diagnostic': (await FlutterPatcher.lastBootDiagnostic)?.status.name,
          };
        case '/check':
          final check = await FlutterPatcher.checkUpdate(body['url'] as String);
          if (!check.hasUpdate) {
            out = {'update': false};
          } else {
            final result = await FlutterPatcher.applyPatch(check.patch!);
            out = {'update': true, 'ok': result.ok, 'error': result.error?.name};
          }
        case '/rollback':
          await FlutterPatcher.rollback();
          out = {'ok': true};
        default:
          request.response.statusCode = HttpStatus.notFound;
      }
      request.response.write(jsonEncode(out));
    } catch (e) {
      request.response.statusCode = HttpStatus.conflict;
      request.response.write(jsonEncode({'error': '$e'}));
    } finally {
      await request.response.close();
    }
  });
}