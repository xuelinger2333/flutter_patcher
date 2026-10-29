// `flutter_patcher mock-server`: the v1 SO mock update server for hosts
// without a host policy, with the options of the former bin/mock_server.dart.
import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:crypto/crypto.dart' as crypto;

const _defaultCheckPath = '/check';
const _legacyPayload = 'libapp.so';

class MockServerUsageException implements Exception {
  MockServerUsageException(this.message, this.exitCode);

  final String message;
  final int exitCode;

  @override
  String toString() => message;
}

class MockPatch {
  MockPatch({
    required this.patchFile,
    required this.bytes,
    required this.version,
    required this.md5,
    required this.targetVersionCode,
    required this.payload,
  });

  final File patchFile;
  final List<int> bytes;
  final String version;
  final String md5;
  final int? targetVersionCode;
  final String payload;
}

class MockPatchServerConfig {
  MockPatchServerConfig({
    required this.patch,
    this.host = '0.0.0.0',
    this.port = 8080,
    this.checkPath = _defaultCheckPath,
    String? patchPath,
  }) : patchPath = patchPath ?? '/${patch.payload}';

  final MockPatch patch;
  final String host;
  final int port;
  final String checkPath;
  final String patchPath;
}

class MockPatchServer {
  MockPatchServer(this._server, this.config);

  final HttpServer _server;
  final MockPatchServerConfig config;

  int get port => _server.port;

  Future<void> close({bool force = false}) async {
    await _server.close(force: force);
  }
}

Future<int> mockServerMain(List<String> argv) async {
  final parser = buildArgParser();
  final ArgResults args;
  try {
    args = parser.parse(argv);
  } on FormatException catch (e) {
    stderr.writeln('error: ${e.message}');
    stderr.writeln(_usage(parser));
    exitCode = 64;
    return 64;
  }

  if (args['help'] as bool) {
    stdout.writeln(_usage(parser));
    return 0;
  }

  try {
    final patch = await loadMockPatch(
      dist: args['dist'] as String?,
      patch: args['patch'] as String?,
      manifest: args['manifest'] as String?,
      version: args['version'] as String?,
      md5Override: args['md5'] as String?,
      targetVersionCode: _parseOptionalInt(
        args['target-version-code'] as String?,
        '--target-version-code',
      ),
    );
    final port = _parseRequiredInt(args['port'] as String, '--port');
    final host = args['host'] as String;
    final server = await startMockPatchServer(
      MockPatchServerConfig(patch: patch, host: host, port: port),
    );
    await printServerInfo(server);
    await _waitForever();
    return 0;
  } on MockServerUsageException catch (e) {
    stderr.writeln('error: ${e.message}');
    stderr.writeln(_usage(parser));
    exitCode = e.exitCode;
    return e.exitCode;
  }
}

ArgParser buildArgParser() => ArgParser()
  ..addOption(
    'dist',
    help: 'Directory containing manifest.json and the packed payload.',
  )
  ..addOption('patch',
      help: 'Path to a patch payload (libapp.so or patch.zip).')
  ..addOption(
    'manifest',
    help:
        'Optional manifest.json. Defaults to <dist>/manifest.json with --dist.',
  )
  ..addOption(
    'version',
    help: 'Patch version. Overrides manifest.version. Defaults to mock-1.',
  )
  ..addOption(
    'target-version-code',
    help: 'Host APK versionCode. Overrides manifest.targetVersionCode.',
  )
  ..addOption(
    'md5',
    help:
        'Patch MD5. Overrides manifest.md5; computed automatically if absent.',
  )
  ..addOption(
    'host',
    defaultsTo: '0.0.0.0',
    help: 'Host/interface to bind. Use 0.0.0.0 for phone access over Wi-Fi.',
  )
  ..addOption('port', defaultsTo: '8080', help: 'Port to listen on.')
  ..addFlag('help', abbr: 'h', negatable: false, help: 'Show help.');

Future<MockPatch> loadMockPatch({
  String? dist,
  String? patch,
  String? manifest,
  String? version,
  String? md5Override,
  int? targetVersionCode,
}) async {
  if (dist != null && patch != null) {
    throw MockServerUsageException(
        'use either --dist or --patch, not both.', 64);
  }
  if (dist == null && patch == null) {
    throw MockServerUsageException('one of --dist or --patch is required.', 64);
  }

  final manifestFile = manifest != null
      ? File(manifest)
      : (dist != null ? File('$dist/manifest.json') : null);
  final manifestJson = await _readManifestIfPresent(manifestFile);
  final payload = _parsePayload(manifestJson, patch);
  final patchFile = File(patch ?? '$dist/$payload');
  if (!patchFile.existsSync()) {
    throw MockServerUsageException(
        'patch file not found: ${patchFile.path}', 66);
  }

  final bytes = await patchFile.readAsBytes();

  final resolvedVersion =
      version ?? (manifestJson['version'] as String?) ?? 'mock-1';
  final resolvedMd5 = md5Override ??
      (manifestJson['md5'] as String?) ??
      crypto.md5.convert(bytes).toString();
  final resolvedTargetVersionCode =
      targetVersionCode ?? _parseManifestVersionCode(manifestJson);

  return MockPatch(
    patchFile: patchFile,
    bytes: bytes,
    version: resolvedVersion,
    md5: resolvedMd5,
    targetVersionCode: resolvedTargetVersionCode,
    payload: payload,
  );
}

Future<MockPatchServer> startMockPatchServer(
  MockPatchServerConfig config,
) async {
  final server = await HttpServer.bind(config.host, config.port);
  final mockServer = MockPatchServer(server, config);

  server.listen((req) async {
    final host = req.headers.value('host') ?? 'localhost:${server.port}';
    final patchUrl = 'http://$host${config.patchPath}';

    if (req.uri.path == config.checkPath) {
      req.response
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({
          'hasUpdate': true,
          'patch': {
            'version': config.patch.version,
            'patchUrl': patchUrl,
            'md5': config.patch.md5,
            if (config.patch.targetVersionCode != null)
              'targetVersionCode': config.patch.targetVersionCode,
          },
        }));
    } else if (req.uri.path == config.patchPath) {
      req.response
        ..headers.contentType = ContentType('application', 'octet-stream')
        ..headers.contentLength = config.patch.bytes.length
        ..add(config.patch.bytes);
    } else if (req.uri.path == '/') {
      req.response
        ..headers.contentType = ContentType.text
        ..write(_indexText(host, config));
    } else {
      req.response.statusCode = HttpStatus.notFound;
      req.response.write('not found\n');
    }

    await req.response.close();
  });

  return mockServer;
}

Future<void> printServerInfo(MockPatchServer server) async {
  final patch = server.config.patch;
  stdout.writeln('[mock_server] serving ${patch.patchFile.path}');
  stdout.writeln('[mock_server] payload=${patch.payload}');
  stdout.writeln('[mock_server] version=${patch.version}, md5=${patch.md5}');
  if (patch.targetVersionCode != null) {
    stdout
        .writeln('[mock_server] targetVersionCode=${patch.targetVersionCode}');
  }
  stdout.writeln(
    '[mock_server] listening on ${server.config.host}:${server.port}',
  );

  final urls = await localCheckUrls(server.port);
  for (final url in urls) {
    stdout.writeln('[mock_server] phone URL: $url');
  }
  stdout.writeln(
    '[mock_server] emulator tip: adb reverse tcp:${server.port} tcp:${server.port}',
  );
}

Future<List<String>> localCheckUrls(int port) async {
  final urls = <String>[];
  final interfaces = await NetworkInterface.list(
    includeLoopback: false,
    type: InternetAddressType.IPv4,
  );
  for (final interface in interfaces) {
    for (final address in interface.addresses) {
      urls.add('http://${address.address}:$port$_defaultCheckPath');
    }
  }
  if (urls.isEmpty) {
    urls.add('http://127.0.0.1:$port$_defaultCheckPath');
  }
  return urls;
}

Future<Map<String, dynamic>> _readManifestIfPresent(File? manifestFile) async {
  if (manifestFile == null) return const {};
  if (!manifestFile.existsSync()) {
    throw MockServerUsageException(
      'manifest not found: ${manifestFile.path}',
      66,
    );
  }
  final decoded = jsonDecode(await manifestFile.readAsString());
  if (decoded is! Map<String, dynamic>) {
    throw MockServerUsageException('manifest must be a JSON object.', 65);
  }
  return decoded;
}

int? _parseManifestVersionCode(Map<String, dynamic> manifestJson) {
  final raw =
      manifestJson['targetVersionCode'] ?? manifestJson['target_version_code'];
  if (raw == null) return null;
  if (raw is num) return raw.toInt();
  if (raw is String && raw.isNotEmpty) return int.tryParse(raw);
  return null;
}

int? _parseOptionalInt(String? raw, String name) {
  if (raw == null || raw.isEmpty) return null;
  return _parseRequiredInt(raw, name);
}

int _parseRequiredInt(String raw, String name) {
  final parsed = int.tryParse(raw);
  if (parsed == null) {
    throw MockServerUsageException('$name must be an integer.', 64);
  }
  return parsed;
}

String _usage(ArgParser parser) => 'flutter_patcher mock_server CLI\n\n'
    'usage:\n'
    '  dart run flutter_patcher:mock_server --dist dist [--port 8080]\n'
    '  dart run flutter_patcher:mock_server --patch dist/libapp.so '
    '[--manifest dist/manifest.json]\n\n'
    '${parser.usage}';

String _parsePayload(Map<String, dynamic> manifestJson, String? explicitPatch) {
  if (explicitPatch != null) {
    return Uri.file(explicitPatch).pathSegments.last;
  }
  final raw = manifestJson['payload'];
  if (raw is String && raw.trim().isNotEmpty) {
    final payload = raw.trim();
    if (payload.contains('/') ||
        payload.contains('\\') ||
        payload.contains('..')) {
      throw MockServerUsageException(
          'manifest.payload must be a file name.', 65);
    }
    return payload;
  }
  return _legacyPayload;
}

String _indexText(String host, MockPatchServerConfig config) =>
    'flutter_patcher mock server\n\n'
    'GET http://$host${config.checkPath}\n'
    'GET http://$host${config.patchPath}\n\n'
    'Dart:\n'
    "final check = await FlutterPatcher.checkUpdate('http://$host${config.checkPath}');\n"
    'if (check.hasUpdate) {\n'
    '  await FlutterPatcher.applyPatch(check.patch!);\n'
    '}\n';

Future<void> _waitForever() async {
  while (true) {
    await Future<void>.delayed(const Duration(days: 1));
  }
}
