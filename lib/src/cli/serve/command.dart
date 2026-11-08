import 'dart:async';
import 'dart:io';

import 'package:args/args.dart';
import 'package:path/path.dart' as p;

import '../core.dart';
import '../project.dart';
import '../publish/command.dart';
import '../publish/store.dart';
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

/// Hands patches to development devices: publishes each new patch output of
/// the project to its store, serves the store's patch files on 127.0.0.1 and
/// maps that port onto connected Android devices with adb reverse. Devices
/// still verify every file; only the transport is local.
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
  final reversed = <String>{}, offered = <String>{};
  final offers = <String, int>{};
  while (!stop.isCompleted) {
    await _reverse(port, reversed);
    await _offerLatest(project, offered);
    await _announce(root, offers);
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
Future<void> _respond(HttpRequest request, String root) async {
  final response = request.response;
  try {
    final name = request.uri.path.substring(1);
    final file = File(p.join(root, name));
    var named = true;
    try {
      publicationName(name);
    } on Failure {
      named = false;
    }
    if (request.method != 'GET' ||
        request.uri.hasQuery ||
        !named ||
        !await file.exists()) {
      response.statusCode = HttpStatus.notFound;
    } else {
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

/// Publishes the newest finished patch output once, unless it was published
/// before: a restart must not bring back a patch since withdrawn or replaced.
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
      onlyNew: true,
    );
    if (result['status'] == 'published_before') {
      stderr.writeln(
        'Not offering the latest patch output again: it was published as '
        '${result['seq']}. To offer it again, run '
        '`dart run flutter_patcher publish --patch $latest`.',
      );
    }
  } on Failure catch (error) {
    stderr.writeln('Not offered: ${error.code}: ${error.message}');
  }
}

/// Says what devices are offered whenever a patch file in the store
/// changes, whoever published it.
Future<void> _announce(String root, Map<String, int> offers) async {
  await for (final file in Directory(root).list()) {
    final name = p.basename(file.path);
    if (file is! File || !name.endsWith('.fptc')) continue;
    final PatchHeader header;
    try {
      final handle = await file.open();
      try {
        header = PatchHeader.parse(await handle.read(patchHeaderSize));
      } finally {
        await handle.close();
      }
    } catch (_) {
      continue; // Being replaced; the next pass reads it.
    }
    final known = offers[name];
    if (known == header.seq) continue;
    offers[name] = header.seq;
    stderr.writeln(
      header.withdrawal
          ? 'Withdrawn as ${header.seq} ($name): devices that apply it run '
                'the installed version'
          : 'Offering patch ${header.seq} ($name)'
                '${known == null ? '' : '; restart the app after it applies'}',
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
