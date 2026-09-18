// Dedicated release acceptance application; never shipped in the plugin.
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_patcher/flutter_patcher.dart';

const revision = 'original';
const customBinding = bool.fromEnvironment('WP9_CUSTOM_BINDING');

class AcceptanceBinding extends WidgetsFlutterBinding {}

Future<void> main() async {
  if (customBinding) {
    AcceptanceBinding();
  } else {
    WidgetsFlutterBinding.ensureInitialized();
  }
  await FlutterPatcher.init();
  var message = 'pending';
  var frame = false;
  var themeType = 'unknown';
  WidgetsBinding.instance.addPostFrameCallback((_) {
    frame = true;
  });
  runApp(MaterialApp(home: Builder(builder: (context) {
    themeType = Theme.of(context).runtimeType.toString();
    return FutureBuilder<String>(
        future: DefaultAssetBundle.of(context)
            .loadString('assets/message.txt')
            .then((value) {
          message = value;
          return value;
        }),
        builder: (context, snapshot) => Scaffold(
                body: Column(children: [
              Text('WP9:$revision:${snapshot.data ?? "pending"}'),
              const Icon(Icons.home),
              // WP25_FEATURE is replaced only in the WP-2.5 patch fixtures.
            ])));
  })));
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 8766);
  server.listen((request) async {
    request.response.headers.contentType = ContentType.json;
    try {
      if (request.method == 'GET' && request.uri.path == '/status') {
        final diagnostic = await FlutterPatcher.lastBootDiagnostic;
        request.response.write(jsonEncode({
          'revision': revision,
          'asset': message,
          'frame': frame,
          'pid': pid,
          'binding': WidgetsBinding.instance is AcceptanceBinding,
          'themeType': themeType,
          'diagnostic': diagnostic?.toString(),
          'version': await FlutterPatcher.currentVersion
        }));
      } else if (request.method == 'POST' && request.uri.path == '/update') {
        final body = jsonDecode(await utf8.decoder.bind(request).join())
            as Map<String, dynamic>;
        final client = HttpClient();
        try {
          final check =
              await (await client.getUrl(Uri.parse(body['url'] as String)))
                  .close();
          final state = jsonDecode(await utf8.decoder.bind(check).join())
              as Map<String, dynamic>;
          if (state['rollback'] == true) {
            await FlutterPatcher.rollback();
            request.response.write('{"rollback":true}');
          } else {
            final update = PatchCheckResult.fromJson(state);
            if (!update.hasUpdate || update.patch == null) {
              throw StateError('No test update');
            }
            final result = await FlutterPatcher.applyPatch(update.patch!);
            request.response.write(jsonEncode({
              'ok': result.ok,
              'error': result.error?.name,
              'message': result.message
            }));
          }
        } finally {
          client.close(force: true);
        }
      } else {
        request.response.statusCode = HttpStatus.notFound;
      }
    } catch (error) {
      request.response.statusCode = HttpStatus.internalServerError;
      request.response.write(jsonEncode({'error': error.toString()}));
    } finally {
      await request.response.close();
    }
  });
}
