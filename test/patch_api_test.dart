import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_patcher/flutter_patcher.dart';
import 'package:flutter_test/flutter_test.dart';

/// The Dart API for FPTC v1 patch files, against a fake native side and a
/// local HTTP server.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('flutter_patcher');
  const scope = {
    'application_id': 'com.example.app',
    'channel': 'production',
    'flavor': 'default',
    'version_code': '7',
    'abi': 'arm64-v8a',
    'fingerprint':
        'abababababababababababababababababababababababababababababababab',
    'strategy': 'bytecode',
  };
  const fileName = '7-arm64-v8a.fptc';

  late HttpServer server;
  late String base;
  final files = <String, List<int>>{};
  final ranges = <String?>[];
  var honourRange = true;
  final calls = <MethodCall>[];
  Map<String, dynamic> inspection = {};
  Map<String, dynamic> applied = {'ok': true, 'action': 'publish'};
  final appliedBytes = <List<int>>[];

  /// A patch file of [length] bytes whose header claims [seq].
  Uint8List patchFile(int seq, int length) {
    final bytes = Uint8List(length);
    ByteData.sublistView(bytes)
      ..setUint32(0, 0x46505443)
      ..setUint16(4, 1)
      ..setUint32(38, seq)
      ..setUint64(42, length - 146);
    for (var i = 146; i < length; i++) {
      bytes[i] = i % 251;
    }
    return bytes;
  }

  setUpAll(() async {
    FlutterPatcher.debugAssumeSupported = true;
    // The test binding answers every request with 400; talk to the real server.
    HttpOverrides.global = null;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = 'http://127.0.0.1:${server.port}/patches';
    server.listen((request) async {
      ranges.add(request.headers.value(HttpHeaders.rangeHeader));
      final body = files[request.uri.path];
      if (body == null) {
        request.response.statusCode = 404;
      } else if (request.uri.path.endsWith('broken.fptc')) {
        request.response.statusCode = 500;
      } else if (honourRange &&
          request.headers.value(HttpHeaders.rangeHeader) == 'bytes=0-145') {
        request.response.statusCode = 206;
        request.response.add(body.sublist(0, 146));
      } else {
        request.response.add(body);
      }
      await request.response.close();
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          switch (call.method) {
            case 'hostStrategy':
              return 'bytecode';
            case 'hostUrl':
              return '$base/';
            case 'patchTarget':
              return {'scope': scope, 'signed': true, 'acceptedSeq': 41};
            case 'inspectPatch':
              return inspection;
            case 'applyPatchFile':
              final path = call.arguments['path'] as String;
              if (path.endsWith('fail')) {
                throw PlatformException(code: 'PATCH_REJECTED', message: 'no');
              }
              appliedBytes.add(File(path).readAsBytesSync());
              return applied;
          }
          return null;
        });
  });

  tearDownAll(() => server.close(force: true));

  setUp(() {
    files.clear();
    ranges.clear();
    calls.clear();
    appliedBytes.clear();
    honourRange = true;
    inspection = {
      'fresh': true,
      'action': 'publish',
      'seq': 42,
      'reason': null,
    };
    applied = {'ok': true, 'action': 'publish'};
  });

  List<int> inspectedHeader() =>
      calls.singleWhere((c) => c.method == 'inspectPatch').arguments['header']
          as List<int>;

  group('patchTarget', () {
    test('names the host, its file and the sequence it accepted', () async {
      final target = await FlutterPatcher.patchTarget;
      expect(target.fileName, fileName);
      expect(target.versionCode, '7');
      expect(target.flavor, 'default');
      expect(target.channel, 'production');
      expect(target.abi, 'arm64-v8a');
      expect(target.strategy, 'bytecode');
      expect(target.fingerprint, scope['fingerprint']);
      expect(target.signed, isTrue);
      expect(target.acceptedSeq, 41);
    });
  });

  group('checkUpdate', () {
    test('reads only the header of <url>/<fileName>', () async {
      final file = patchFile(42, 4096);
      files['/patches/$fileName'] = file;
      final result = await FlutterPatcher.checkUpdate(url: base);
      expect(ranges, ['bytes=0-145']);
      expect(inspectedHeader(), file.sublist(0, 146));
      expect(result.hasUpdate, isTrue);
      expect(result.patch!.version, '42');
    });

    test('reads 146 bytes when the server sends the whole file', () async {
      honourRange = false;
      final file = patchFile(42, 1 << 20);
      files['/patches/$fileName'] = file;
      expect((await FlutterPatcher.checkUpdate(url: base)).hasUpdate, isTrue);
      expect(inspectedHeader(), file.sublist(0, 146));
    });

    test('defaults to the address the build wrote into the app', () async {
      files['/patches/$fileName'] = patchFile(42, 300);
      expect((await FlutterPatcher.checkUpdate()).hasUpdate, isTrue);
    });

    test('finds no update where there is no file', () async {
      expect((await FlutterPatcher.checkUpdate(url: base)).hasUpdate, isFalse);
      expect(calls.where((c) => c.method == 'inspectPatch'), isEmpty);
    });

    test('finds no update in a file the host would not take', () async {
      files['/patches/$fileName'] = patchFile(40, 300);
      inspection = {
        'fresh': false,
        'action': 'publish',
        'seq': 40,
        'reason': 'Not newer than the accepted patch',
      };
      expect((await FlutterPatcher.checkUpdate(url: base)).hasUpdate, isFalse);
    });

    test('reports a withdrawal as an update', () async {
      files['/patches/$fileName'] = patchFile(43, 146);
      inspection = {
        'fresh': true,
        'action': 'withdraw',
        'seq': 43,
        'reason': null,
      };
      final result = await FlutterPatcher.checkUpdate(url: base);
      expect(result.hasUpdate, isTrue);
      expect(result.patch!.raw['action'], 'withdraw');
    });

    test('refuses plain HTTP to another machine', () async {
      await expectLater(
        FlutterPatcher.checkUpdate(url: 'http://example.com/patches'),
        throwsA(isA<PatcherException>()),
      );
    });

    test('a directory with no file for this host is no update', () async {
      files['/patches/$fileName'] = patchFile(42, 300);
      await expectLater(
        FlutterPatcher.checkUpdate(url: '$base/missing-dir'),
        completion(predicate<PatchCheckResult>((r) => !r.hasUpdate)),
      );
    });
  });

  group('applyPatch', () {
    test('downloads the whole file and hands it to native code', () async {
      final file = patchFile(42, 70000);
      files['/patches/$fileName'] = file;
      final check = await FlutterPatcher.checkUpdate(url: base);
      final progress = <PatchApplyProgress>[];
      final result = await FlutterPatcher.applyPatch(
        check.patch!,
        onProgress: progress.add,
      );
      expect(result.ok, isTrue);
      expect(appliedBytes.single, file);
      final path = calls.last.arguments['path'] as String;
      expect(File(path).existsSync(), isFalse);
      expect(progress.first.phase, PatchApplyPhase.downloading);
      expect(progress.last.bytesReceived, file.length);
    });

    test('reports a failed download as a network error', () async {
      files['/patches/broken.fptc'] = patchFile(42, 300);
      final result = await FlutterPatcher.applyPatch(
        PatchInfo(
          version: '42',
          raw: {'url': '$base/broken.fptc', 'size': 300},
        ),
      );
      expect(result.error, PatchApplyError.network);
      expect(appliedBytes, isEmpty);
    });

    test('rejects a PatchInfo checkUpdate did not return', () async {
      final result = await FlutterPatcher.applyPatch(
        const PatchInfo(version: '1'),
      );
      expect(result.error, PatchApplyError.invalidArgs);
    });
  });

  group('applyPatchBytes and applyPatchFile', () {
    test('bytes reach native code in a file removed afterwards', () async {
      final file = patchFile(42, 500);
      applied = {'ok': false, 'error': 'INVALID_ARGS', 'message': 'old'};
      final result = await FlutterPatcher.applyPatchBytes(file);
      expect(result.error, PatchApplyError.invalidArgs);
      expect(result.message, 'old');
      expect(appliedBytes.single, file);
      expect(
        File(calls.last.arguments['path'] as String).existsSync(),
        isFalse,
      );
    });

    test('a file is passed by its path and left in place', () async {
      final dir = await Directory.systemTemp.createTemp('fp-api-');
      final file = File('${dir.path}/$fileName')
        ..writeAsBytesSync(patchFile(42, 500));
      expect((await FlutterPatcher.applyPatchFile(file.path)).ok, isTrue);
      expect(calls.last.arguments['path'], file.path);
      expect(file.existsSync(), isTrue);
    });

    test('a native failure is a result, not an exception', () async {
      final result = await FlutterPatcher.applyPatchFile('/nowhere/fail');
      expect(result.ok, isFalse);
      expect(result.error, PatchApplyError.unknown);
      expect(result.message, 'no');
    });
  });

  group('inspectPatch', () {
    test('passes the first 146 bytes and returns what native found', () async {
      final file = patchFile(42, 500);
      final result = await FlutterPatcher.inspectPatch(file);
      expect(inspectedHeader(), file.sublist(0, 146));
      expect(result.fresh, isTrue);
      expect(result.action, 'publish');
      expect(result.seq, 42);
      expect(result.reason, isNull);
    });
  });
}
