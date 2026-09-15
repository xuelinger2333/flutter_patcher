import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:args/args.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import '../core.dart';

ArgParser publishOptions() => ArgParser()
  ..addFlag('help', abbr: 'h', negatable: false)
  ..addFlag('production',
      negatable: false,
      help: 'Explicit production protocol; default is still local mock.')
  ..addFlag('commit',
      negatable: false,
      help: 'Commit a production request; otherwise preview only.')
  ..addOption('request', help: 'Production request JSON file.')
  ..addOption('receipt', help: 'New output JSON file for production result.')
  ..addOption('action',
      defaultsTo: 'stage', allowed: ['stage', 'serve', 'withdraw'])
  ..addOption('out',
      help: 'Explicit local mock directory (never a remote service).')
  ..addOption('patch', help: 'Signed FPTC from patch android.')
  ..addOption('version-code')
  ..addOption('port', defaultsTo: '8765');

/// Staging checks transport identity; the device remains responsible for trust.
Map<String, Object> mockMetadata(Uint8List bytes, int versionCode) {
  require(bytes.length >= 146 && bytes.length <= 320 * 1024 * 1024,
      'MOCK_PATCH_INVALID', 'Envelope size');
  final h = ByteData.sublistView(bytes);
  require(
      h.getUint32(0) == 0x46505443 &&
          h.getUint16(4) == 1 &&
          h.getUint64(42) == bytes.length - 146 &&
          h.getUint32(38) > 0 &&
          versionCode > 0,
      'MOCK_PATCH_INVALID',
      'Envelope identity or versionCode');
  String hex(List<int> b) =>
      b.map((v) => v.toRadixString(16).padLeft(2, '0')).join();
  require(
      sha256.convert(bytes.sublist(146)).toString() ==
          hex(bytes.sublist(50, 82)),
      'MOCK_PATCH_INVALID',
      'Envelope payload hash');
  return {
    'version': 'bytecode-${h.getUint32(38)}',
    'strategy': 'bytecode',
    'sha256': sha256.convert(bytes).toString(),
    'fingerprint': hex(bytes.sublist(6, 38)),
    'patch_seq': h.getUint32(38),
    'targetVersionCode': versionCode,
  };
}

Future<void> writeMockState(
    String directory, Map<String, Object?> state) async {
  await rejectLinks(directory);
  await Directory(directory).create(recursive: true);
  final destination = p.join(directory, 'current.json');
  await rejectLinks(destination);
  final temporary = File(p.join(directory,
      '.current-$pid-${DateTime.now().microsecondsSinceEpoch}.json'));
  await temporary.writeAsString(jsonEncode(state), flush: true);
  await temporary.rename(destination);
}

Future<HttpServer> serveMock(String directory, int port) async {
  await rejectLinks(directory);
  require(await Directory(directory).exists(), 'MOCK_CONFIG_INVALID',
      'Mock directory missing');
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
  server.listen((request) async {
    try {
      if (request.method != 'GET') {
        request.response.statusCode = HttpStatus.methodNotAllowed;
      } else if (request.uri.path == '/check') {
        final file = File(p.join(directory, 'current.json'));
        await rejectLinks(file.path);
        final state =
            jsonDecode(await file.readAsString()) as Map<String, dynamic>;
        if (state['hasUpdate'] == true) {
          final patch = state['patch'] as Map<String, dynamic>;
          // adb reverse makes this same loopback address reachable on the device.
          patch['patchUrl'] =
              'http://127.0.0.1:${server.port}/${patch['sha256']}.fptc';
        }
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode(state));
      } else if (RegExp(r'^/[a-f0-9]{64}\.fptc$').hasMatch(request.uri.path)) {
        final file = File(p.join(directory, request.uri.path.substring(1)));
        await rejectLinks(file.path);
        if (!await file.exists()) {
          request.response.statusCode = HttpStatus.notFound;
        } else {
          request.response.headers.contentType = ContentType.binary;
          await request.response.addStream(file.openRead());
        }
      } else {
        request.response.statusCode = HttpStatus.notFound;
      }
    } catch (_) {
      request.response.statusCode = HttpStatus.internalServerError;
    } finally {
      await request.response.close();
    }
  });
  return server;
}

Future<int> publishCommand(ArgResults args) async {
  require(
      args['commit'] != true &&
          args['request'] == null &&
          args['receipt'] == null,
      'USAGE_ERROR',
      'Production options require --production');
  require(args.rest.isEmpty, 'USAGE_ERROR', 'Unexpected positional arguments');
  final output = args['out'] as String?;
  require(output != null && output.isNotEmpty, 'MOCK_CONFIG_INVALID',
      'Specify --out for the local mock');
  final directory = p.absolute(output!);
  final action = args['action'];
  if (action == 'serve') {
    final port = int.tryParse(args['port'] as String);
    require(port != null && port >= 0 && port <= 65535, 'MOCK_CONFIG_INVALID',
        'Invalid port');
    final server = await serveMock(directory, port!);
    stdout.writeln(jsonEncode({
      'command': 'publish',
      'scope': 'local_mock',
      'check_url': 'http://127.0.0.1:${server.port}/check'
    }));
    return 0; // The HttpServer subscription keeps the process alive.
  }
  if (action == 'withdraw') {
    await writeMockState(directory, {'hasUpdate': false, 'rollback': true});
  } else {
    final source = args['patch'] as String?;
    require(source != null, 'MOCK_CONFIG_INVALID', 'Specify --patch');
    final file = File(source!);
    require(await file.length() <= 320 * 1024 * 1024, 'MOCK_PATCH_INVALID',
        'Envelope size');
    final bytes = await file.readAsBytes();
    final metadata = mockMetadata(
        bytes, int.tryParse(args['version-code'] as String? ?? '') ?? 0);
    await rejectLinks(directory);
    await Directory(directory).create(recursive: true);
    final target = File(p.join(directory, '${metadata['sha256']}.fptc'));
    await rejectLinks(target.path);
    if (await target.exists()) {
      require(await hashFile(target.path) == metadata['sha256'],
          'MOCK_PATCH_INVALID', 'Existing payload changed');
    } else {
      await target.writeAsBytes(bytes, flush: true);
    }
    await writeMockState(directory, {'hasUpdate': true, 'patch': metadata});
  }
  stdout.writeln(jsonEncode({
    'command': 'publish',
    'scope': 'local_mock',
    'action': action,
    'out': directory
  }));
  return 0;
}
