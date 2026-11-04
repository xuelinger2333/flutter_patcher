// Test-only static HTTPS server on port 8443: 127.0.0.1 (reached through adb
// reverse) or the given LAN address (an iPhone on the same network).
// Usage: dart tls_server.dart ROOT KEYSTORE.p12 PASSWORD [BIND_ADDRESS]
// The runner reads READY and the request log from stdout.
// ignore_for_file: avoid_print
import 'dart:io';

Future<void> main(List<String> args) async {
  final root = Directory(args[0]).absolute.uri;
  final p12 = File(args[1]).readAsBytesSync();
  final context = SecurityContext()
    ..useCertificateChainBytes(p12, password: args[2])
    ..usePrivateKeyBytes(p12, password: args[2]);
  final server = await HttpServer.bindSecure(
    args.length > 3 ? InternetAddress(args[3]) : InternetAddress.loopbackIPv4,
    8443,
    context,
  );
  print('READY');
  await for (final request in server) {
    final file = File.fromUri(root.resolve(request.uri.path.substring(1)));
    final ok = !request.uri.path.contains('..') && file.existsSync();
    request.response.statusCode = ok ? 200 : 404;
    if (ok) {
      request.response.contentLength = file.lengthSync();
      await request.response.addStream(file.openRead());
    }
    await request.response.close();
    print(
      '${request.method} ${request.uri.path} ${request.response.statusCode}',
    );
  }
}
