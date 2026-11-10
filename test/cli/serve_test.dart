// The serve cases run the CLI in a subprocess, which compiles it first.
@Timeout(Duration(minutes: 3))
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'package:flutter_patcher/src/cli/core.dart';
import 'package:flutter_patcher/src/cli/patch/outputs.dart';
import 'package:flutter_patcher/src/cli/patch/package.dart';
import 'package:flutter_patcher/src/cli/publish/seal.dart';
import 'package:flutter_patcher/src/patch_file.dart';

import 'host_tools.dart';

/// `serve`, a debugging aid: devices get the newest file `patch` wrote for
/// each host, as it is; serve never signs, numbers, stores or publishes.
void main() {
  late Directory root;
  late String project;
  final processes = <Process>[];
  var outputs = 0;
  final fingerprint = 'ef' * 32;
  final signedKey = base64Encode(List.filled(32, 7));
  Map<String, String> scope(String versionCode) => {
    'application_id': 'com.example.app',
    'channel': 'production',
    'flavor': 'default',
    'version_code': versionCode,
    'abi': 'arm64-v8a',
    'fingerprint': fingerprint,
    'strategy': 'bytecode',
  };
  String name(String versionCode) => patchFileName(scope(versionCode));

  setUp(() async {
    root = await Directory.systemTemp.createTemp('serve-');
    project = p.join(root.path, 'app');
    await Directory(project).create();
  });
  tearDown(() async {
    for (final process in processes) {
      process.kill();
      await process.exitCode;
    }
    processes.clear();
    await root.delete(recursive: true);
  });

  /// A finished output of `patch` for the host [versionCode]; with [seq] it
  /// holds its file, a patch or a withdrawal.
  Future<String> output(
    String versionCode, {
    int? seq,
    bool withdrawal = false,
    String patchKey = '-',
  }) async {
    final dir = p.join(patchOutputsRoot(project), '${1000000 + outputs++}');
    await writeObject(p.join(dir, 'patch.json'), {
      'status': withdrawal ? 'withdrawal_created' : 'patch_created',
      'scope': scope(versionCode),
      'patch_key': patchKey,
    });
    if (withdrawal) {
      if (seq != null) {
        File(p.join(dir, name(versionCode)))
            .writeAsBytesSync(await sealWithdrawal(fingerprint, seq: seq));
      }
      return dir;
    }
    final module = File(p.join(root.path, 'module-$outputs.bc'))
      ..writeAsStringSync('code $outputs');
    final draft = await packPatch(
      kind: 'bytecode',
      code: module.path,
      metadata: {'fingerprint': fingerprint, 'module_id': 9, 'tier': 'lean'},
    );
    await draft.write(dir);
    if (seq != null) {
      File(p.join(dir, name(versionCode)))
          .writeAsBytesSync(await sealPatch(draft, seq: seq));
    }
    return dir;
  }

  group('the newest file of each host', () {
    test('is the newest output\'s, which an older one never stands in '
        'for', () async {
      await output('7', seq: 10);
      final newest = await output('7', seq: 20);
      final other = await output('8', seq: 30);
      await output('9', seq: 5);
      final unsigned = await output('9', patchKey: signedKey);
      final files = await latestFiles(project);
      expect(files.keys, unorderedEquals([name('7'), name('8'), name('9')]));
      expect(files[name('7')]!.file, p.join(newest, name('7')));
      expect(files[name('8')]!.output, other);
      expect(files[name('9')]!.output, unsigned);
      expect(files[name('9')]!.file, isNull);
      expect(files[name('9')]!.signed, isTrue);
    });

    test('passes over outputs being written and outputs of 1.0', () async {
      final kept = await output('7', seq: 10);
      await writeObject(
        p.join(patchOutputsRoot(project), '9999999.pending-1', 'patch.json'),
        {'status': 'patch_created', 'scope': scope('7'), 'patch_key': '-'},
      );
      await writeObject(
        p.join(patchOutputsRoot(project), '9999998', 'patch.json'),
        {'status': 'patch_created', 'scope': scope('7')},
      );
      expect((await latestFiles(project))[name('7')]!.output, kept);
    });
  });

  group('serve', () {
    late List<String> log;
    late int port;

    Future<void> until(bool Function() done, String what) async {
      for (var i = 0; i < 240 && !done(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
      expect(done(), isTrue, reason: '$what; serve said:\n${log.join('\n')}');
    }

    Future<void> serve() async {
      final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      port = socket.port;
      await socket.close();
      log = [];
      final process = await Process.start(dartVm, [
        p.absolute('bin/flutter_patcher.dart'),
        'serve',
        '--project',
        project,
        '--port',
        '$port',
      ]);
      processes.add(process);
      process.stdout.drain<void>();
      process.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(log.add);
      await until(() => log.any((l) => l.startsWith('Serving')), 'started');
      // serve answers before its first scan; the first announcement follows it.
      await until(
        () => log.any(
          (l) => l.startsWith('Offering') || l.startsWith('Not offering'),
        ),
        'first scan',
      );
    }

    Future<(int, List<int>)> get(String path, {bool header = false}) async {
      final client = HttpClient();
      try {
        final request = await client.get('127.0.0.1', port, '/$path');
        if (header) request.headers.set(HttpHeaders.rangeHeader, 'bytes=0-145');
        final response = await request.close();
        final body = await response.fold<List<int>>([], (a, b) => a..addAll(b));
        return (response.statusCode, body);
      } finally {
        client.close(force: true);
      }
    }

    test('offers the newest file of each host, whole or its header, and '
        'nothing else', () async {
      await output('7', seq: 10);
      final newest = await output('7', seq: 20);
      await output('8', seq: 30);
      await serve();
      final (status, body) = await get(name('7'));
      expect(status, HttpStatus.ok);
      expect(body, File(p.join(newest, name('7'))).readAsBytesSync());
      final (partial, header) = await get(name('7'), header: true);
      expect(partial, HttpStatus.partialContent);
      expect(header, body.sublist(0, patchHeaderSize));
      expect(PatchHeader.parse((await get(name('8'))).$2).seq, 30);
      for (final other in [name('9'), 'patch.json', '1000001/patch.json']) {
        expect((await get(other)).$1, HttpStatus.notFound, reason: other);
      }
      await until(
        () => log.any(
          (l) => l.contains('Offering patch 20 (${name('7')}, unsigned)'),
        ),
        'announced',
      );
    });

    test(
      'follows the outputs patch writes while it runs, a withdrawal too',
      () async {
        await output('7', seq: 10);
        await serve();
        expect(PatchHeader.parse((await get(name('7'))).$2).seq, 10);
        await output('7', seq: 20, withdrawal: true);
        late List<int> body;
        await until(
          () => log.any((l) => l.contains('Offering a withdrawal')),
          'withdrawal announced',
        );
        body = (await get(name('7'))).$2;
        expect(body.length, patchHeaderSize);
        expect(PatchHeader.parse(body).withdrawal, isTrue);
        expect(PatchHeader.parse(body).seq, 20);
      },
    );

    test('says why the newest output of a host has no file, and offers no '
        'older one', () async {
      await output('7', seq: 10);
      await output('7', patchKey: signedKey);
      await serve();
      await until(() => log.any((l) => l.contains('keys import')), 'explained');
      expect((await get(name('7'))).$1, HttpStatus.notFound);
    });

    test('touches no store, whichever the project names', () async {
      await File(p.join(project, 'flutter_patcher.yaml'))
          .writeAsString('store: s3://bucket/patches\n');
      await output('7', seq: 10);
      await serve();
      expect((await get(name('7'))).$1, HttpStatus.ok);
      expect(
        Directory(p.join(project, '.flutter_patcher')).existsSync(),
        isFalse,
      );
    });
  });
}
