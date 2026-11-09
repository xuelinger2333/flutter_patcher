import 'dart:async';
import 'dart:io';

import 'package:args/args.dart';
import 'package:path/path.dart' as p;

import '../core.dart';
import '../patch/outputs.dart';
import '../project.dart';
import '../../patch_file.dart';

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

/// A debugging aid: hands development devices the newest file `patch` wrote
/// for each host, a patch or a withdrawal, as it is. It serves them on
/// 127.0.0.1 and maps that port onto connected Android devices with adb
/// reverse. It never signs, numbers, stores or publishes anything: devices
/// verify each file as they verify any other.
Future<int> serveCommand(ArgResults args) async {
  final project = p.absolute(
    args['project'] as String? ?? Directory.current.path,
  );
  final port = int.tryParse(args['port'] as String);
  require(
    port != null && port > 0 && port < 65536,
    'USAGE_ERROR',
    'Invalid --port',
  );
  final HttpServer server;
  try {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, port!);
  } on SocketException {
    throw Failure(
      'SERVE_PORT_BUSY',
      'Port $port is in use on this computer; choose another with --port.',
    );
  }
  var files = await latestFiles(project);
  server.listen((request) => _respond(request, files));
  final url = 'http://127.0.0.1:$port';
  stderr.writeln(
    'Serving the patch files in ${patchOutputsRoot(project)} at $url\n'
    'Apps check here with FlutterPatcher.checkUpdate(url: \'$url\'), or '
    'checkUpdate() when built without url in ${ProjectConfig.file}.\n'
    'iOS or another network: expose $url over HTTPS, for example with '
    '`cloudflared tunnel --url $url`, and pass that address.\n'
    'After a change run `dart run flutter_patcher patch android` (or ios); '
    'Ctrl+C stops.',
  );
  final stop = Completer<void>();
  final signal = ProcessSignal.sigint.watch().listen((_) {
    if (!stop.isCompleted) stop.complete();
  });
  final reversed = <String>{};
  final announced = <String, HostFile>{};
  while (!stop.isCompleted) {
    await _reverse(port, reversed);
    files = await latestFiles(project);
    await _announce(files, announced);
    await Future.any([
      stop.future,
      Future<void>.delayed(const Duration(seconds: 2)),
    ]);
  }
  await signal.cancel();
  await server.close(force: true);
  return 0;
}

/// Devices read only patch files, whole or the first bytes a check asks for.
Future<void> _respond(HttpRequest request, Map<String, HostFile> files) async {
  final response = request.response;
  try {
    final name = request.uri.path.substring(1);
    final path = files[name]?.file;
    if (request.method != 'GET' ||
        request.uri.hasQuery ||
        path == null ||
        !await File(path).exists()) {
      response.statusCode = HttpStatus.notFound;
    } else {
      final file = File(path);
      final length = await file.length();
      final range = RegExp(r'^bytes=0-(\d+)$')
          .firstMatch(request.headers.value(HttpHeaders.rangeHeader) ?? '');
      final end = range == null
          ? length - 1
          : (int.parse(range[1]!)).clamp(0, length - 1);
      response.headers.contentType = ContentType.binary;
      if (range != null) {
        response.statusCode = HttpStatus.partialContent;
        response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes 0-$end/$length',
        );
      }
      response.contentLength = end + 1;
      await response.addStream(file.openRead(0, end + 1));
      stderr.writeln(
        range != null
            ? 'A device checked for updates'
            : 'A device downloaded $name',
      );
    }
    await response.close();
  } catch (_) {
    // A device that disconnects mid-response retries on its next check.
  }
}

/// Says what devices are offered whenever the newest output of a host
/// changes.
Future<void> _announce(
  Map<String, HostFile> files,
  Map<String, HostFile> announced,
) async {
  for (final MapEntry(key: name, value: host) in files.entries) {
    final before = announced[name];
    if (before?.output == host.output) continue;
    announced[name] = host;
    final path = host.file;
    if (path == null) {
      stderr.writeln(
        'Not offering $name: ${host.output} has no patch file. Its host '
        'accepts only files signed by its patch key, which this machine does '
        'not have; run `dart run flutter_patcher keys import` and patch '
        'again.',
      );
      continue;
    }
    final PatchHeader header;
    try {
      final handle = await File(path).open();
      try {
        header = PatchHeader.parse(await handle.read(patchHeaderSize));
      } finally {
        await handle.close();
      }
    } catch (error) {
      stderr.writeln('Not offering $name: $path: $error');
      continue;
    }
    final signed = host.signed ? 'signed' : 'unsigned';
    stderr.writeln(
      header.withdrawal
          ? 'Offering a withdrawal of $name ($signed, ${header.seq}): devices '
                'that apply it run the installed version'
          : 'Offering patch ${header.seq} ($name, $signed)'
                '${before == null ? '' : '; restart the app after it applies'}',
    );
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
