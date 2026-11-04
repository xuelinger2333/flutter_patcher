// Device fixture for authenticated hosts (SO or bytecode). Test-only trust: the
// CA is accepted by this app alone, via HttpOverrides and its native NSC on
// Android; on iOS the device trusts the test CA (native downloads use it).
//
// Control: Android serves 127.0.0.1:8767 (reached through adb forward). iOS
// has no forward: the runner copies Documents/flutter_patcher_command.json
// ({"id","path","body"}) into the app, launches it and reads
// Documents/flutter_patcher_test.json back. Platform.environment is empty in an
// iOS app, so the container comes from fixture_support (host-side FFI).
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:fixture_support/fixture_support.dart';
import 'package:flutter_patcher/flutter_patcher.dart';

const revision = 'original';
// A crash patch throws before its first frame; crash protection must recover.
// (exit() is not a crash: Android records it as a deliberate self exit.)
const crash = false;
const testCa = r"""__TEST_CA__""";

class _TestTrust extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      super.createHttpClient(
        SecurityContext(withTrustedRoots: true)
          ..setTrustedCertificatesBytes(utf8.encode(testCa)),
      );
}

Future<Object?> handle(String path, Map body, String asset) async {
  switch (path) {
    case '/status':
      return {
        'revision': revision,
        'asset': asset,
        'version': await FlutterPatcher.currentVersion,
        'diagnostic': (await FlutterPatcher.lastBootDiagnostic)?.status.name,
      };
    case '/check':
      final check = await FlutterPatcher.checkUpdate(body['url'] as String);
      if (!check.hasUpdate) return {'update': false};
      final result = await FlutterPatcher.applyPatch(check.patch!);
      return {'update': true, 'ok': result.ok, 'error': result.error?.name};
    case '/rollback':
      await FlutterPatcher.rollback();
      return {'ok': true};
  }
  throw const HttpException('not found');
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = _TestTrust();
  await FlutterPatcher.init();
  if (crash) throw StateError('crash patch');
  final asset = await rootBundle.loadString('assets/msg.txt');
  runApp(
    MaterialApp(
      home: Scaffold(body: Center(child: Text('revision: $revision\n$asset'))),
    ),
  );
  if (Platform.isIOS) {
    final documents = '${iosHome()}/Documents';
    // Evidence of how far a launch got when no result appears.
    await File('$documents/flutter_patcher_started.json')
        .writeAsString(jsonEncode({'revision': revision}));
    final command = File('$documents/flutter_patcher_command.json');
    if (!await command.exists()) return;
    final request = jsonDecode(await command.readAsString()) as Map;
    await command.delete();
    if (request['path'] == '/status') {
      // Let the first frame settle the boot attempt, as the Android runner does.
      await Future<void>.delayed(const Duration(seconds: 6));
    }
    Object? out;
    try {
      out = await handle(
        request['path'] as String,
        request['body'] as Map? ?? const {},
        asset,
      );
    } catch (e) {
      out = {'http': HttpStatus.conflict, 'error': '$e'};
    }
    await File('$documents/flutter_patcher_test.json')
        .writeAsString(jsonEncode({'id': request['id'], 'result': out}));
    return;
  }
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 8767);
  server.listen((request) async {
    request.response.headers.contentType = ContentType.json;
    try {
      final body = request.method == 'POST'
          ? jsonDecode(await utf8.decoder.bind(request).join()) as Map
          : const {};
      request.response.write(
        jsonEncode(await handle(request.uri.path, body, asset)),
      );
    } on HttpException {
      request.response.statusCode = HttpStatus.notFound;
      request.response.write('null');
    } catch (e) {
      request.response.statusCode = HttpStatus.conflict;
      request.response.write(jsonEncode({'error': '$e'}));
    } finally {
      await request.response.close();
    }
  });
}
