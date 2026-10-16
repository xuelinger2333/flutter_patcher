import 'dart:async';
import 'dart:io';
import 'package:path/path.dart' as p;
import '../core.dart';
import 'manifest.dart';

abstract class BaselineStore {
  Future<void> probe();
  Future<bool> get(String name, String destination);

  /// False means an object already exists. Callers must verify its content.
  Future<bool> put(String name, String source);
  static BaselineStore open(Uri uri, Commands commands,
      {bool offline = false}) {
    require(
        uri.userInfo.isEmpty && uri.query.isEmpty && uri.fragment.isEmpty,
        'CONFIG_INVALID',
        'Store URLs cannot contain credentials, queries or fragments.');
    if (uri.scheme == 'file') return FileBaselineStore(uri.toFilePath());
    require(!offline, 'BASELINE_STORE_UNREACHABLE',
        'Remote baseline store is unavailable offline.');
    if (uri.scheme == 's3') return S3BaselineStore(uri, commands);
    Downloads.validateUri(uri);
    return HttpBaselineStore(uri,
        token: Platform.environment['FLUTTER_PATCHER_BASELINE_TOKEN']);
  }
}

/// Legacy `baseline-<fp>` + sidecar `release-….json`; schema 5 `compile-<fp>`,
/// `release-….tar.zst` and the APK attestation `apk-<sha256>.json`.
void objectName(String name) => require(
    RegExp(r'^((baseline|compile)-[0-9a-f]{64}\.tar\.zst|release-[A-Za-z0-9_-]+-[0-9]+-arm64-v8a\.(json|tar\.zst)|apk-[0-9a-f]{64}\.json)$')
        .hasMatch(name),
    'CONFIG_INVALID',
    'Invalid baseline object name.');

/// Also serialize same-process callers: POSIX locks are process-scoped.
final _queues = <String, Future<void>>{};
Future<T> serialized<T>(String key, Future<T> Function() action) async {
  final previous = _queues[key] ?? Future<void>.value();
  final done = Completer<void>();
  _queues[key] = done.future;
  await previous;
  try {
    return await action();
  } finally {
    done.complete();
    if (identical(_queues[key], done.future)) _queues.remove(key);
  }
}

class FileBaselineStore implements BaselineStore {
  final String root;
  FileBaselineStore(String path) : root = p.normalize(p.absolute(path));
  @override
  Future<void> probe() async {
    await rejectLinks(root);
    require(await Directory(root).exists(), 'BASELINE_STORE_UNREACHABLE',
        'File store directory does not exist.');
  }

  @override
  Future<bool> get(String name, String destination) async {
    objectName(name);
    await probe();
    final source = p.join(root, name);
    await rejectLinks(source);
    await rejectLinks(destination);
    if (!await File(source).exists()) return false;
    valid(await File(source).length() <= 1024 * 1024 * 1024,
        'Stored baseline exceeds size limit.');
    valid(!await File(destination).exists(), 'Download target exists.');
    await File(source).copy(destination);
    return true;
  }

  @override
  Future<bool> put(String name, String source) => serialized(root, () async {
        objectName(name);
        await probe();
        final target = p.join(root, name),
            lockPath = p.join(root, '.baseline-store.lock');
        await rejectLinks(target);
        await rejectLinks(lockPath);
        final lock = await File(lockPath).open(mode: FileMode.append);
        await lock.lock(FileLock.blockingExclusive);
        try {
          if (await File(target).exists()) return false;
          final pending = temporaryName(target);
          await File(source).copy(pending);
          valid(await hashFile(pending) == await hashFile(source),
              'Store copy failed verification.');
          await File(pending).renameRetry(target);
          return true;
        } finally {
          await lock.unlock();
          await lock.close();
        }
      });
}

class HttpBaselineStore implements BaselineStore {
  final Uri base;
  final String? token;
  final int maxBytes;
  HttpBaselineStore(this.base,
      {this.token, this.maxBytes = 1024 * 1024 * 1024}) {
    Downloads.validateUri(base);
  }
  Future<int> request(String method, String? name,
      {String? source, String? destination}) async {
    if (name != null) objectName(name);
    final uri = name == null
        ? base
        : base.replace(
            path: '${base.path.replaceFirst(RegExp(r'/$'), '')}/$name');
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 30);
    IOSink? sink;
    try {
      final req = await client
          .openUrl(method, uri)
          .timeout(const Duration(seconds: 30));
      req.followRedirects =
          false; // Never forward credentials across redirects.
      if (token != null) req.headers.set('Authorization', 'Bearer $token');
      if (source != null) {
        req.headers.set('If-None-Match', '*');
        req.headers.contentType = ContentType.binary;
        req.contentLength = await File(source).length();
        await req
            .addStream(File(source).openRead())
            .timeout(const Duration(minutes: 10));
      }
      final response = await req.close().timeout(const Duration(seconds: 60));
      final code = response.statusCode;
      if (method == 'GET' && code == 200) {
        valid(response.contentLength <= maxBytes,
            'Baseline download exceeds limit.');
        await rejectLinks(destination!);
        valid(!await File(destination).exists(), 'Download target exists.');
        sink = File(destination).openWrite();
        var size = 0;
        await for (final chunk
            in response.timeout(const Duration(seconds: 60))) {
          size += chunk.length;
          valid(size <= maxBytes, 'Baseline download exceeds limit.');
          sink.add(chunk);
        }
        await sink.flush();
      } else {
        await response.drain<void>().timeout(const Duration(seconds: 60));
      }
      return code;
    } on Failure {
      rethrow;
    } catch (_) {
      throw Failure('BASELINE_STORE_UNREACHABLE',
          'Baseline HTTP request failed ($method).');
    } finally {
      await sink?.close();
      client.close(force: true);
    }
  }

  @override
  Future<void> probe() async => require(await request('HEAD', null) == 200,
      'BASELINE_STORE_UNREACHABLE', 'Store HEAD probe failed.');
  @override
  Future<bool> get(String name, String destination) async {
    final code = await request('GET', name, destination: destination);
    if (code == 404) return false;
    require(code == 200, 'BASELINE_STORE_UNREACHABLE',
        'Store GET failed (HTTP $code).');
    return true;
  }

  @override
  Future<bool> put(String name, String source) async {
    final code = await request('PUT', name, source: source);
    if (code == 412) return false;
    require(code == 201, 'BASELINE_STORE_PROTOCOL',
        'Store must support atomic If-None-Match:* PUT, return 201 on creation and 412 on conflict (HTTP $code).');
    return true;
  }
}

/// AWS CLI supplies its standard credential chain; secrets never enter arguments.
/// Requires s3api put-object --if-none-match support; writes fail if unavailable.
class S3BaselineStore implements BaselineStore {
  final Uri uri;
  final Commands commands;
  final String executable;
  S3BaselineStore(this.uri, this.commands, {this.executable = 'aws'}) {
    require(uri.host.isNotEmpty && !uri.pathSegments.contains('..'),
        'CONFIG_INVALID', 'Invalid S3 store URI.');
  }
  Future<CommandResult> call(String operation, List<String> args) async {
    final endpoint = commands.environment['FLUTTER_PATCHER_S3_ENDPOINT'];
    if (endpoint != null) Downloads.validateUri(Uri.parse(endpoint));
    try {
      return await commands.runResult(
          executable,
          [
            if (endpoint != null) ...['--endpoint-url', endpoint],
            's3api',
            operation,
            '--bucket',
            uri.host,
            ...args,
          ],
          code: 'BASELINE_STORE_UNREACHABLE',
          extraEnvironment: {'AWS_PAGER': ''});
    } catch (_) {
      throw Failure('BASELINE_STORE_UNREACHABLE',
          'AWS CLI could not run; configure its standard credentials.');
    }
  }

  String key(String name) {
    objectName(name);
    return [...uri.pathSegments.where((s) => s.isNotEmpty), name].join('/');
  }

  @override
  Future<void> probe() async => require(
      (await call('head-bucket', [])).exitCode == 0,
      'BASELINE_STORE_UNREACHABLE',
      'S3 bucket probe failed.');
  @override
  Future<bool> get(String name, String destination) async {
    await rejectLinks(destination);
    valid(!await File(destination).exists(), 'Download target exists.');
    final r = await call('get-object',
        ['--key', key(name), '--range', 'bytes=0-1073741824', destination]);
    if (r.exitCode != 0 && RegExp(r'\((NoSuchKey|404)\)').hasMatch(r.stderr)) {
      return false;
    }
    require(r.exitCode == 0, 'BASELINE_STORE_UNREACHABLE', 'S3 GET failed.');
    valid(await File(destination).length() <= 1024 * 1024 * 1024,
        'Stored baseline exceeds size limit.');
    return true;
  }

  @override
  Future<bool> put(String name, String source) async {
    final r = await call('put-object',
        ['--key', key(name), '--body', source, '--if-none-match', '*']);
    if (r.exitCode != 0 && r.stderr.contains('(PreconditionFailed)')) {
      return false;
    }
    require(r.exitCode == 0, 'BASELINE_STORE_PROTOCOL',
        'S3 conditional PUT failed; use an AWS CLI/service supporting If-None-Match.');
    return true;
  }
}
