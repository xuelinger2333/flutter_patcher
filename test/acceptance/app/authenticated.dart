// Dedicated network acceptance fixture. Its loopback API is not plugin code.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_patcher/flutter_patcher.dart';

const revision = 'original';
class AcceptanceBinding extends WidgetsFlutterBinding {}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await FlutterPatcher.init();
  var frame = false;
  WidgetsBinding.instance.addPostFrameCallback((_) { frame = true; });
  runApp(MaterialApp(home: Scaffold(body: Column(children: [
    Text('Authenticated:$revision'), const Icon(Icons.home),
  ]))));
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 8767);
  server.listen((request) async {
    request.response.headers.contentType = ContentType.json;
    try {
      if (request.uri.path == '/status') {
        request.response.write(jsonEncode({'revision': revision, 'frame': frame,
          'pid': pid, 'version': await FlutterPatcher.currentVersion,
          'diagnostic': (await FlutterPatcher.lastBootDiagnostic)?.toString()}));
      } else {
        final body = jsonDecode(await utf8.decoder.bind(request).join()) as Map;
        if (request.uri.path == '/signed') {
          final document = await FlutterPatcher.fetchSignedManifest(body['url'] as String);
          final result = await FlutterPatcher.applySignedManifest(document);
          request.response.write(jsonEncode({'ok': result.result.ok,
            'action': result.action, 'error': result.result.error?.name}));
        } else if (request.uri.path == '/trust') {
          final document = await FlutterPatcher.fetchSignedManifest(body['url'] as String);
          await FlutterPatcher.updatePublicationTrust(document);
          request.response.write('{"ok":true}');
        } else if (request.uri.path == '/bare') {
          final result = await FlutterPatcher.applyPatch(PatchInfo.fromJson(
              Map<String, dynamic>.from(body)));
          request.response.write(jsonEncode({'ok': result.ok}));
        } else if (request.uri.path == '/direct') {
          const channel = MethodChannel('flutter_patcher');
          await channel.invokeMethod<void>('saveConfig', {'publicKeyBase64': '', 'strictSignature': false});
          final result = await channel.invokeMethod<Object?>('applyPatch', {
            'version': 'bypass', 'patchUrl': 'https://example.com/no-fetch', 'strategy': 'bytecode'});
          request.response.write(jsonEncode(result));
        } else if (request.uri.path == '/bare-bytes') {
          final result = await FlutterPatcher.applyPatchBytes(Uint8List.fromList([1,2,3]), version: 'bypass');
          request.response.write(jsonEncode({'ok': result.ok}));
        } else if (request.uri.path == '/rollback') {
          await FlutterPatcher.rollback();
          request.response.write('{"ok":true}');
        } else { request.response.statusCode = HttpStatus.notFound; }
      }
    } catch (_) {
      // Signed URLs are credentials: never echo exception text or request bodies.
      request.response.statusCode = HttpStatus.conflict;
      request.response.write('{"ok":false,"error":"rejected"}');
    } finally { await request.response.close(); }
  });
}
