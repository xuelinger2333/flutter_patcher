import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

class Failure implements Exception {
  final String code;
  final String message;
  Failure(this.code, this.message);
  @override
  String toString() => '$code: $message';
}

void require(bool condition, String code, String message) {
  if (!condition) throw Failure(code, message);
}

Future<String> hashFile(String path) async =>
    (await sha256.bind(File(path).openRead()).first).toString();

Future<Map<String, dynamic>> readObject(String path) async {
  try {
    final text = await File(path).readAsString();
    loadYaml(
        text); // Reject duplicate mapping keys before JSON decoding loses them.
    final value = jsonDecode(text);
    if (value is! Map<String, dynamic>) throw const FormatException();
    return value;
  } catch (_) {
    throw Failure('ENGINE_MANIFEST_INVALID', 'Invalid JSON object: $path');
  }
}

String temporaryName(String path) =>
    '$path.pending-$pid-${DateTime.now().microsecondsSinceEpoch}';

Future<void> writeObject(String path, Map<String, dynamic> value) async {
  await Directory(p.dirname(path)).create(recursive: true);
  final staging = File(temporaryName(path));
  await staging.writeAsString(
      '${const JsonEncoder.withIndent('  ').convert(value)}\n',
      flush: true);
  await staging.rename(path);
}

/// Existing invalid data is retained for diagnosis instead of silently reused.
Future<void> quarantine(String path) async {
  final type = await FileSystemEntity.type(path, followLinks: false);
  final target = '$path.invalid-${DateTime.now().microsecondsSinceEpoch}';
  if (type == FileSystemEntityType.directory) {
    await Directory(path).rename(target);
  } else if (type == FileSystemEntityType.file) {
    await File(path).rename(target);
  } else if (type == FileSystemEntityType.link) {
    throw Failure('CACHE_INVALID', 'Symbolic link is not permitted: $path');
  }
}

Future<void> rejectLinks(String path) async {
  var current = p.absolute(path);
  while (true) {
    require(
        await FileSystemEntity.type(current, followLinks: false) !=
            FileSystemEntityType.link,
        'CACHE_INVALID',
        'Cache path contains a symbolic link: $current');
    final parent = p.dirname(current);
    if (parent == current) break;
    current = parent;
  }
}

class Commands {
  final Map<String, String> environment;
  Commands(String cache)
      : environment = {
          ...Platform.environment,
          'PUB_CACHE': p.join(cache, 'pub-cache'),
          'CI': 'true',
          'FLUTTER_SUPPRESS_ANALYTICS': 'true'
        } {
    environment.remove('FLUTTER_STORAGE_BASE_URL');
    for (final key in [
      'FLUTTER_TOOL_ARGS',
      'FLUTTER_PREBUILT_ENGINE_VERSION',
      'FLUTTER_REALM',
      'GIT_DIR',
      'GIT_INDEX_FILE',
      'GIT_WORK_TREE'
    ]) {
      environment.remove(key);
    }
  }

  Future<String> run(String executable, List<String> args,
      {String? cwd,
      String code = 'TOOL_FAILED',
      Duration timeout = const Duration(minutes: 15),
      Map<String, String>? extraEnvironment}) async {
    final result = await runResult(executable, args,
        cwd: cwd,
        code: code,
        timeout: timeout,
        extraEnvironment: extraEnvironment);
    if (result.exitCode != 0) {
      final detail = '${result.stderr}\n${result.stdout}'.trim();
      throw Failure(
          code,
          '${p.basename(executable)} exited ${result.exitCode}: '
          '${detail.length > 6000 ? detail.substring(detail.length - 6000) : detail}');
    }
    return result.stdout;
  }

  Future<CommandResult> runResult(String executable, List<String> args,
      {String? cwd,
      String code = 'TOOL_FAILED',
      Duration timeout = const Duration(minutes: 15),
      Map<String, String>? extraEnvironment}) async {
    Process process;
    try {
      process = await Process.start(executable, args,
          workingDirectory: cwd,
          environment: {...environment, ...?extraEnvironment},
          includeParentEnvironment: false);
    } on ProcessException catch (error) {
      throw Failure(code, 'Cannot start $executable: ${error.message}');
    }
    final output = process.stdout.transform(utf8.decoder).join();
    final diagnostic = process.stderr.transform(utf8.decoder).join();
    int result;
    try {
      result = await process.exitCode.timeout(timeout);
    } on TimeoutException {
      process.kill(ProcessSignal.sigkill);
      throw Failure(code,
          'Timed out running ${p.basename(executable)} ${args.take(2).join(' ')}');
    }
    final out = await output;
    final err = await diagnostic;
    return CommandResult(result, out, err);
  }
}

class CommandResult {
  final int exitCode;
  final String stdout, stderr;
  CommandResult(this.exitCode, this.stdout, this.stderr);
}

class Downloads {
  final bool offline;
  int requests = 0;
  Downloads({this.offline = false});

  static void validateUri(Uri uri) {
    require(
        uri.scheme == 'https' ||
            (uri.scheme == 'http' &&
                ['127.0.0.1', 'localhost', '::1'].contains(uri.host)),
        'CONFIG_INVALID',
        'Use HTTPS (HTTP is allowed only for loopback test servers).');
    require(uri.userInfo.isEmpty && uri.fragment.isEmpty, 'CONFIG_INVALID',
        'Artifact URLs must not contain credentials or fragments.');
  }

  Future<void> fetch(Uri uri, String destination,
      {String missingCode = 'ENGINE_ARTIFACT_MISSING',
      int maxBytes = 512 * 1024 * 1024}) async {
    validateUri(uri);
    require(!offline, missingCode, 'Not available in offline cache: $uri');
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 30);
    IOSink? sink;
    try {
      var next = uri;
      HttpClientResponse? response;
      for (var redirect = 0; redirect <= 5; redirect++) {
        validateUri(next);
        requests++;
        final request =
            await client.getUrl(next).timeout(const Duration(seconds: 30));
        request.followRedirects = false;
        request.headers.set('User-Agent', 'flutter-patcher-cli');
        if (next.host == 'api.github.com') {
          request.headers.set('Accept', 'application/vnd.github.raw+json');
        }
        response = await request.close().timeout(const Duration(seconds: 60));
        if ([301, 302, 303, 307, 308].contains(response.statusCode)) {
          final location = response.headers.value('location');
          require(location != null, missingCode,
              'Download redirect has no location.');
          next = next.resolve(location!);
          continue;
        }
        break;
      }
      require(response?.statusCode == 200, missingCode,
          'Download failed (HTTP ${response?.statusCode}): $uri');
      require(response!.contentLength <= maxBytes, 'ARTIFACT_INVALID',
          'Download exceeds size limit.');
      await rejectLinks(destination);
      await Directory(p.dirname(destination)).create(recursive: true);
      sink = File(destination).openWrite();
      var bytes = 0;
      await for (final chunk in response.timeout(const Duration(seconds: 60))) {
        bytes += chunk.length;
        require(bytes <= maxBytes, 'ARTIFACT_INVALID',
            'Download exceeds size limit.');
        sink.add(chunk);
      }
      await sink.flush();
    } on Failure {
      rethrow;
    } catch (error) {
      throw Failure(missingCode, 'Download failed for $uri: $error');
    } finally {
      await sink?.close();
      client.close(force: true);
    }
  }
}
