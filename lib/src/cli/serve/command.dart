import 'dart:async';
import 'dart:io';

import 'package:args/args.dart';
import 'package:path/path.dart' as p;

import '../core.dart';
import '../project.dart';
import '../publish/command.dart';

ArgParser serveOptions() => ArgParser()
  ..addFlag('help', abbr: 'h', negatable: false)
  ..addOption(
    'project',
    help: 'Application directory; default the current one.',
  )
  ..addOption(
    'port',
    defaultsTo: '8686',
    help:
        'Port on this computer, and through adb reverse on Android '
        'devices.',
  );

/// Hands patches to development devices: publishes each new patch output of
/// the project to its store, serves the store on 127.0.0.1 and maps that port
/// onto connected Android devices with adb reverse. Devices still verify every
/// manifest and patch; only the transport is local.
Future<int> serveCommand(ArgResults args) async {
  final project = p.absolute(
    args['project'] as String? ?? Directory.current.path,
  );
  final config = await ProjectConfig.load(project);
  final store = Uri.parse(config.store);
  require(
    store.scheme == 'file',
    'SERVE_CONFIG_INVALID',
    'serve offers a file:// store, not ${config.store}; remove store from '
        '${ProjectConfig.file} while developing.',
  );
  final port = int.tryParse(args['port'] as String);
  require(
    port != null && port > 0 && port < 65536,
    'USAGE_ERROR',
    'Invalid --port',
  );
  final root = store.toFilePath();
  await rejectLinks(root);
  await Directory(root).create(recursive: true);
  final HttpServer server;
  try {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, port!);
  } on SocketException {
    throw Failure(
      'SERVE_PORT_BUSY',
      'Port $port is in use on this computer; choose another with --port.',
    );
  }
  server.listen((request) => _respond(request, root));
  final url = 'http://127.0.0.1:$port';
  stderr.writeln(
    'Serving $root at $url\n'
    'In the app: FlutterPatcher.checkUpdate(\'$url\')\n'
    'iOS or another network: expose $url over HTTPS, for example with '
    '`cloudflared tunnel --url $url`, and pass that URL instead.\n'
    'After a change run `dart run flutter_patcher patch android` (or ios); '
    'Ctrl+C stops.',
  );
  final stop = Completer<void>();
  final signal = ProcessSignal.sigint.watch().listen((_) {
    if (!stop.isCompleted) stop.complete();
  });
  final reversed = <String>{}, offered = <String>{};
  while (!stop.isCompleted) {
    await _reverse(port, reversed);
    await _offerLatest(project, offered);
    await Future.any([
      stop.future,
      Future<void>.delayed(const Duration(seconds: 2)),
    ]);
  }
  await signal.cancel();
  await server.close(force: true);
  return 0;
}

/// Devices read only signed manifests and the patches they name.
Future<void> _respond(HttpRequest request, String root) async {
  final response = request.response;
  try {
    final name = request.uri.path.substring(1);
    final file = File(p.join(root, name));
    if (request.method != 'GET' ||
        request.uri.hasQuery ||
        !(RegExp(r'^manifests/[a-f0-9]{64}\.json$').hasMatch(name) ||
            RegExp(r'^objects/[a-f0-9]{32}/[a-f0-9]{64}\.fptc$')
                .hasMatch(name)) ||
        !await file.exists()) {
      response.statusCode = HttpStatus.notFound;
    } else {
      response.headers.contentType = name.endsWith('.json')
          ? ContentType.json
          : ContentType.binary;
      response.contentLength = await file.length();
      await response.addStream(file.openRead());
      stderr.writeln(
        name.endsWith('.json')
            ? 'A device checked for updates'
            : 'A device downloaded the patch',
      );
    }
    await response.close();
  } catch (_) {
    // A device that disconnects mid-response retries on its next check.
  }
}

/// Publishes the newest finished patch output once, unless it is already
/// its scope's head: republishing would only make devices fetch it again.
Future<void> _offerLatest(String project, Set<String> offered) async {
  final latest = await latestPatchOutput(project);
  if (latest == null || !offered.add(latest)) return;
  try {
    final result = await publication(
      publishOptions().parse([
        '--project',
        project,
        '--patch',
        latest,
        '--yes',
      ]),
    );
    stderr.writeln(
      result['status'] == 'already_published'
          ? 'Offering patch ${result['patch_seq']}'
          : 'Offering patch ${result['patch_seq']} '
                '(revision ${result['revision']}); restart the app after it '
                'applies',
    );
  } on Failure catch (error) {
    stderr.writeln('Not offered: ${error.code}: ${error.message}');
  }
}

/// Maps the port onto each newly connected Android device.
Future<void> _reverse(int port, Set<String> done) async {
  final sdk =
      Platform.environment['ANDROID_HOME'] ??
      Platform.environment['ANDROID_SDK_ROOT'];
  final bundled = sdk == null
      ? null
      : p.join(sdk, 'platform-tools', Platform.isWindows ? 'adb.exe' : 'adb');
  final adb = bundled != null && File(bundled).existsSync() ? bundled : 'adb';
  ProcessResult devices;
  try {
    devices = await Process.run(adb, ['devices']);
  } on ProcessException {
    return;
  }
  final listed = <String>{};
  for (final line in (devices.stdout as String).split('\n').skip(1)) {
    final parts = line.trim().split(RegExp(r'\s+'));
    if (parts.length != 2 || parts[1] != 'device') continue;
    listed.add(parts[0]);
    if (done.contains(parts[0])) continue;
    final result = await Process.run(adb, [
      '-s',
      parts[0],
      'reverse',
      'tcp:$port',
      'tcp:$port',
    ]);
    if (result.exitCode == 0) {
      done.add(parts[0]);
      stderr.writeln(
        'Android device ${parts[0]} reaches this computer at '
        '127.0.0.1:$port',
      );
    }
  }
  done.retainAll(listed);
}
