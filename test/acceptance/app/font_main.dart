// Dedicated release acceptance application; never shipped in the plugin.
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_patcher/flutter_patcher.dart';

const revision = 'original';
const customBinding = bool.fromEnvironment('CUSTOM_BINDING');

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
  WidgetsBinding.instance.addPostFrameCallback((_) {
    frame = true;
  });
  runApp(MaterialApp(home: Builder(builder: (context) {
    return FutureBuilder<String>(
        future: DefaultAssetBundle.of(context)
            .loadString('assets/message.txt')
            .then((value) {
          message = value;
          return value;
        }),
        builder: (context, snapshot) => Scaffold(
          body: SafeArea(child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Acceptance:$revision:${snapshot.data ?? "pending"}'),
              const SizedBox(height: 32),
              const Text('TEXT FONT REVIEW', style: TextStyle(fontSize: 18)),
              const SizedBox(height: 24),
              const Text('Hamburgefonts 0123456789\nThe quick brown fox\njumps over the lazy dog.\nABCDEFGHIJKLMNOPQRSTUVWXYZ\nabcdefghijklmnopqrstuvwxyz\n!? @ # % & ( )',
                style: TextStyle(fontFamily: 'ReviewText', fontSize: 22, height: 1.6)),
              const SizedBox(height: 32),
              const Text('Original: monospaced\nPatched: bold italic serif\nRollback: monospaced again'),
              const Icon(Icons.home),
            ]),
          )),
        ));
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
