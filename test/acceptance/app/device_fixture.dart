// Device fixture for patchable hosts (SO or bytecode). Test-only trust on
// Android: the CA is accepted by this app alone, via HttpOverrides and its
// native NSC. iOS has no test CA and no route to the computer: the computer
// puts the patch files into the app over the control port, and the app
// serves them to itself under /srv, so it needs no network access.
//
// Control: the app serves 127.0.0.1:8767, reached through adb forward on
// Android and iproxy (usbmuxd) on iOS.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_patcher/flutter_patcher.dart';

const revision = 'original';
// Defines: one the host is built with, one only a patch adds, and one of
// those flutter build adds by itself.
const fixtureEnv = String.fromEnvironment('FIXTURE_ENV', defaultValue: 'unset');
const fixtureAdded = String.fromEnvironment(
  'FIXTURE_ADDED',
  defaultValue: 'unset',
);
const buildName = String.fromEnvironment('FLUTTER_BUILD_NAME');
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

final srv = Directory('${Directory.systemTemp.path}/srv');

/// `POST /put?path=<p>` stores the body as `<p>`; `GET /srv/<p>` serves it,
/// whole, as tls_server.dart does. False for any other request.
Future<bool> files(HttpRequest request) async {
  final path = request.uri.path;
  final put = path == '/put' && request.method == 'POST';
  if (!put && !path.startsWith('/srv/')) return false;
  final name = put
      ? request.uri.queryParameters['path'] ?? ''
      : path.substring(5);
  final file = File('${srv.path}/$name');
  final ok =
      name.isNotEmpty && !name.contains('..') && (put || file.existsSync());
  if (ok && put) {
    await file.parent.create(recursive: true);
    final sink = file.openWrite();
    await sink.addStream(request);
    await sink.close();
  }
  request.response.statusCode = ok ? HttpStatus.ok : HttpStatus.notFound;
  try {
    if (ok && !put) {
      request.response.contentLength = file.lengthSync();
      await request.response.addStream(file.openRead());
    }
    await request.response.close();
  } on Object {
    // checkUpdate stops reading after the header.
  }
  return true;
}

Future<Object?> handle(String path, Map body, String asset) async {
  switch (path) {
    case '/status':
      return {
        'revision': revision,
        'asset': asset,
        'version': await FlutterPatcher.currentVersion,
        'diagnostic': (await FlutterPatcher.lastBootDiagnostic)?.status.name,
        'env': fixtureEnv,
        'added': fixtureAdded,
        'build_name': buildName,
        'available': await FlutterPatcher.isAvailable,
      };
    case '/check':
      final check = await FlutterPatcher.checkUpdate(
        url: body['url'] as String?,
      );
      if (!check.hasUpdate) return {'update': false};
      final result = await FlutterPatcher.applyPatch(check.patch!);
      return {'update': true, 'ok': result.ok, 'error': result.error?.name};
    case '/fetch':
      // The app fetches the file itself, as from its own server.
      final client = HttpClient();
      try {
        final response = await (await client.getUrl(
          Uri.parse(body['url'] as String),
        )).close();
        final bytes = await response.fold<List<int>>(
          [],
          (a, b) => a..addAll(b),
        );
        final result = await FlutterPatcher.applyPatchBytes(bytes);
        return {'ok': result.ok, 'error': result.error?.name};
      } finally {
        client.close();
      }
    case '/target':
      final target = await FlutterPatcher.patchTarget;
      return {
        'file': target.fileName,
        'signed': target.signed,
        'accepted': target.acceptedSeq,
      };
    case '/rollback':
      await FlutterPatcher.rollback();
      return {'ok': true};
  }
  throw const HttpException('not found');
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (testCa.isNotEmpty) HttpOverrides.global = _TestTrust();
  await FlutterPatcher.init();
  if (crash) throw StateError('crash patch');
  final asset = await rootBundle.loadString('assets/msg.txt');
  runApp(
    MaterialApp(
      home: Scaffold(body: Center(child: Text('revision: $revision\n$asset'))),
    ),
  );
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 8767);
  server.listen((request) async {
    if (await files(request)) return;
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
