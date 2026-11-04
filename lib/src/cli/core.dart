import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

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

/// A failure for an error no step anticipated. File system and process
/// errors name their path and the OS's reason (a full disk, a file another
/// process holds); other errors only their type, as their text may quote
/// inputs such as key material.
Failure unexpectedFailure(String code, String what, Object error) {
  if (error is FileSystemException) {
    final os = error.osError;
    if (os != null && _diskFull(os.errorCode)) return _noSpace(error.path);
    final path = error.path == null ? '' : ': ${error.path}';
    final reason = os == null
        ? ''
        : ' (${os.message.trim()}, error ${os.errorCode})';
    return Failure(code, '$what failed: ${error.message}$path$reason.');
  }
  if (error is ProcessException) {
    return Failure(
      code,
      '$what failed: cannot run ${error.executable}: ${error.message.trim()}.',
    );
  }
  return Failure(code, '$what failed (${error.runtimeType}).');
}

/// The failure of a step that exited with [result]: [code], with the last
/// lines the step printed, or `DISK_FULL` when it ran out of space.
Failure stepFailure(
  String code,
  String what,
  CommandResult result,
  String evidence,
) {
  final lines = '${result.stdout}\n${result.stderr}'
      .split('\n')
      .map((line) => line.trim())
      .where((line) => line.isNotEmpty)
      .toList();
  final space = RegExp(r'errno = (\d+)|error (\d+)\)');
  for (final line in lines) {
    final match = space.firstMatch(line);
    final errno = int.tryParse(match?.group(1) ?? match?.group(2) ?? '');
    if (errno != null && _diskFull(errno) || line.contains('No space left')) {
      final path = RegExp(r"path = '([^']+)'").firstMatch(line)?.group(1);
      return _noSpace(path, evidence: evidence);
    }
  }
  final tail = [
    for (final line in lines.skip(lines.length > 2 ? lines.length - 2 : 0))
      line.length > 300 ? '${line.substring(0, 300)}...' : line,
  ].join(' | ');
  return Failure(
    code,
    '$what failed (exit ${result.exitCode})${tail.isEmpty ? '' : ': $tail'}; evidence: $evidence',
  );
}

bool _diskFull(int errno) =>
    Platform.isWindows ? errno == 112 || errno == 39 : errno == 28;

Failure _noSpace(String? path, {String? evidence}) => Failure(
  'DISK_FULL',
  'No space left on the device${path == null ? '' : ' writing $path'}; '
      'free space and retry.'
      '${evidence == null ? '' : ' Evidence: $evidence'}',
);
void require(bool condition, String code, String message) {
  if (!condition) throw Failure(code, message);
}

/// Rejects a directory whose name matches an excluded one only up to case.
/// On a case-insensitive file system tools would write generated output into
/// it, so its contents would differ between hosts; every host rejects it.
void rejectCaseVariant(String name, Iterable<String> excluded, String code) {
  final lower = name.toLowerCase();
  for (final reserved in excluded) {
    require(
      name == reserved || lower != reserved.toLowerCase(),
      code,
      'Directory "$name" differs from the excluded "$reserved" only by case.',
    );
  }
}

/// Resolve the shared CLI cache policy; callers still reject symlinks before I/O.
String managedCache(String? requested, {String? home, String? project}) {
  home ??= Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
  require(home != null, 'CONFIG_INVALID', 'HOME (or USERPROFILE) is not set.');
  final base = p.join(home!, '.flutter_patcher');
  final local = p.join(
    p.absolute(project ?? Directory.current.path),
    '.dart_tool',
    'flutter_patcher',
  );
  final cache = p.normalize(p.absolute(requested ?? base));
  require(
    cache == base ||
        p.isWithin(base, cache) ||
        cache == local ||
        p.isWithin(local, cache),
    'CONFIG_INVALID',
    'Cache must be under ~/.flutter_patcher or this project\'s .dart_tool/flutter_patcher.',
  );
  return cache;
}

Future<String> hashFile(String path) async =>
    (await sha256.bind(File(path).openRead()).first).toString();

Future<Map<String, dynamic>> readObject(String path) async {
  try {
    final text = await File(path).readAsString();
    // Reject duplicate keys before JSON decoding loses them.
    rejectDuplicateJsonKeys(text);
    final value = jsonDecode(text);
    if (value is! Map<String, dynamic>) throw const FormatException();
    return value;
  } catch (_) {
    throw Failure('ENGINE_MANIFEST_INVALID', 'Invalid JSON object: $path');
  }
}

/// Throws [FormatException] if an object in the JSON [text] repeats a key.
/// Only keys are examined; the caller still decodes (and so validates) the
/// text. A linear scan: the YAML parser this replaces took seconds on the
/// multi-megabyte interface files of a real application.
void rejectDuplicateJsonKeys(String text) {
  final objects = <Set<String>?>[]; // null for an array
  var expectKey = false;
  for (var i = 0; i < text.length; i++) {
    final c = text.codeUnitAt(i);
    if (c == 0x22) {
      final start = i;
      var escaped = false;
      for (i++; i < text.length && text.codeUnitAt(i) != 0x22; i++) {
        if (text.codeUnitAt(i) == 0x5C) {
          escaped = true;
          i++;
        }
      }
      if (expectKey) {
        final raw = text.substring(start, i + 1);
        final key = escaped
            ? jsonDecode(raw) as String
            : raw.substring(1, raw.length - 1);
        if (!objects.last!.add(key)) {
          throw FormatException('Duplicate JSON key: $key');
        }
        expectKey = false;
      }
    } else if (c == 0x7B) {
      objects.add(<String>{});
      expectKey = true;
    } else if (c == 0x5B) {
      objects.add(null);
      expectKey = false;
    } else if (c == 0x7D || c == 0x5D) {
      if (objects.isNotEmpty) objects.removeLast();
      expectKey = false;
    } else if (c == 0x2C) {
      expectKey = objects.isNotEmpty && objects.last != null;
    }
  }
}

/// Decodes an interface document: JSON (what the tools write, checked as
/// [rejectDuplicateJsonKeys] does) or, for hand-written files, YAML.
Object? decodeInterface(String text) {
  if (!text.trimLeft().startsWith('{')) return loadYaml(text);
  rejectDuplicateJsonKeys(text);
  return jsonDecode(text);
}

String temporaryName(String path) =>
    '$path.pending-$pid-${DateTime.now().microsecondsSinceEpoch}';

Future<void> writeObject(String path, Map<String, dynamic> value) async {
  await Directory(p.dirname(path)).create(recursive: true);
  final staging = File(temporaryName(path));
  await staging.writeAsString(
    '${const JsonEncoder.withIndent('  ').convert(value)}\n',
    flush: true,
  );
  await staging.renameRetry(path);
}

/// Windows refuses to rename or delete an entry another process still holds
/// open (a Gradle daemon, an indexer, antivirus). Those holds are usually
/// released within a second, so retry briefly before surfacing the error.
/// POSIX never reports these codes, so the operation runs once there.
Future<T> retryOnSharingViolation<T>(Future<T> Function() operation) async {
  const retriable = {
    5,
    32,
    145,
  }; // ACCESS_DENIED, SHARING_VIOLATION, DIR_NOT_EMPTY
  for (var attempt = 0; ; attempt++) {
    try {
      return await operation();
    } on FileSystemException catch (error) {
      if (!Platform.isWindows ||
          attempt >= 10 ||
          !retriable.contains(error.osError?.errorCode)) {
        rethrow;
      }
      await Future<void>.delayed(Duration(milliseconds: 100 * (attempt + 1)));
    }
  }
}

extension SharingViolationRetry on FileSystemEntity {
  Future<void> renameRetry(String target) =>
      retryOnSharingViolation(() => rename(target));
  Future<void> deleteRetry({bool recursive = false}) =>
      retryOnSharingViolation(() => delete(recursive: recursive));
}

/// Existing invalid data is retained for diagnosis instead of silently reused.
Future<void> quarantine(String path) async {
  final type = await FileSystemEntity.type(path, followLinks: false);
  final target = '$path.invalid-${DateTime.now().microsecondsSinceEpoch}';
  if (type == FileSystemEntityType.directory) {
    await Directory(path).renameRetry(target);
  } else if (type == FileSystemEntityType.file) {
    await File(path).renameRetry(target);
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
      'Cache path contains a symbolic link: $current',
    );
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
        'FLUTTER_SUPPRESS_ANALYTICS': 'true',
      } {
    environment.remove('FLUTTER_STORAGE_BASE_URL');
    for (final key in [
      'FLUTTER_TOOL_ARGS',
      'FLUTTER_PREBUILT_ENGINE_VERSION',
      'FLUTTER_REALM',
      'GIT_DIR',
      'GIT_INDEX_FILE',
      'GIT_WORK_TREE',
    ]) {
      environment.remove(key);
    }
  }

  Future<String> run(
    String executable,
    List<String> args, {
    String? cwd,
    List<int>? inputBytes,
    String code = 'TOOL_FAILED',
    Duration timeout = const Duration(minutes: 15),
    Map<String, String>? extraEnvironment,
  }) async {
    final result = await runResult(
      executable,
      args,
      inputBytes: inputBytes,
      cwd: cwd,
      code: code,
      timeout: timeout,
      extraEnvironment: extraEnvironment,
    );
    if (result.exitCode != 0) {
      final detail = '${result.stderr}\n${result.stdout}'.trim();
      throw Failure(
        code,
        '${p.basename(executable)} exited ${result.exitCode}: '
        '${detail.length > 6000 ? detail.substring(detail.length - 6000) : detail}',
      );
    }
    return result.stdout;
  }

  Future<CommandResult> runResult(
    String executable,
    List<String> args, {
    String? cwd,
    List<int>? inputBytes,
    String code = 'TOOL_FAILED',
    Duration timeout = const Duration(minutes: 15),
    Map<String, String>? extraEnvironment,
    String? logPath,
  }) async {
    final started = DateTime.now();
    Process process;
    try {
      // Windows batch launchers (flutter.bat, aws.cmd) only start through the
      // command interpreter; native executables never go through a shell.
      // `cmd /c` strips the outer quotes of a line that starts with a quoted
      // launcher path, so a launcher under a path with spaces breaks once an
      // argument is quoted too; a leading `call` keeps every quote intact.
      final extension = p.extension(executable).toLowerCase();
      final batch =
          Platform.isWindows && (extension == '.bat' || extension == '.cmd');
      process = await Process.start(
        batch ? 'cmd.exe' : executable,
        batch ? ['/c', 'call', executable, ...args] : args,
        workingDirectory: cwd,
        environment: {...environment, ...?extraEnvironment},
        includeParentEnvironment: false,
      );
    } on ProcessException catch (error) {
      throw Failure(code, 'Cannot start $executable: ${error.message}');
    }
    if (inputBytes != null) process.stdin.add(inputBytes);
    final inputClosed = process.stdin.close();
    // A step log is written as output arrives, so a hung or timed-out step
    // still leaves evidence.
    final log = logPath == null ? null : File(logPath).openWrite();
    Stream<List<int>> tee(Stream<List<int>> stream) => log == null
        ? stream
        : stream.map((chunk) {
            log.add(chunk);
            return chunk;
          });
    final output = collectOutput(tee(process.stdout));
    final diagnostic = collectOutput(tee(process.stderr));
    int result;
    try {
      result = await process.exitCode.timeout(timeout);
      await inputClosed;
      trace('${p.basename(executable)} ${_traceArgs(args)}', started);
    } on TimeoutException {
      if (Platform.isWindows) {
        // A .bat runs under cmd.exe; killing only cmd.exe would leave dart.exe
        // and Gradle running, holding the SDK lock and the work directory.
        await Process.run('taskkill', ['/PID', '${process.pid}', '/T', '/F']);
      } else {
        process.kill(ProcessSignal.sigkill);
      }
      await Future.wait([output, diagnostic])
          .timeout(const Duration(seconds: 30), onTimeout: () => const []);
      await log?.close();
      throw Failure(
        code,
        'Timed out after ${timeout.inMinutes} min running ${p.basename(executable)} ${args.take(2).join(' ')}${logPath == null ? '' : '; log: $logPath'}',
      );
    }
    final out = await output;
    final err = await diagnostic;
    await log?.close();
    return CommandResult(result, out, err);
  }
}

/// Tools print UTF-8, but Windows reports its own errors in the ANSI code page
/// (GBK on a Chinese system); undecodable output must never abort a command.
Future<String> collectOutput(Stream<List<int>> stream) async {
  final bytes = await stream.fold<BytesBuilder>(
    BytesBuilder(copy: false),
    (all, chunk) => all..add(chunk),
  );
  final data = bytes.takeBytes();
  try {
    return utf8.decode(data);
  } on FormatException {
    return Platform.isWindows
        ? systemEncoding.decode(data)
        : utf8.decode(data, allowMalformed: true);
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
      'Use HTTPS (HTTP is allowed only for loopback test servers).',
    );
    require(
      uri.userInfo.isEmpty && uri.fragment.isEmpty,
      'CONFIG_INVALID',
      'Artifact URLs must not contain credentials or fragments.',
    );
  }

  Future<void> fetch(
    Uri uri,
    String destination, {
    String missingCode = 'ENGINE_ARTIFACT_MISSING',
    int maxBytes = 512 * 1024 * 1024,
  }) async {
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
        final request = await client
            .getUrl(next)
            .timeout(const Duration(seconds: 30));
        request.followRedirects = false;
        request.headers.set('User-Agent', 'flutter-patcher-cli');
        if (next.host == 'api.github.com') {
          request.headers.set('Accept', 'application/vnd.github.raw+json');
        }
        response = await request.close().timeout(const Duration(seconds: 60));
        if ([301, 302, 303, 307, 308].contains(response.statusCode)) {
          final location = response.headers.value('location');
          require(
            location != null,
            missingCode,
            'Download redirect has no location.',
          );
          next = next.resolve(location!);
          continue;
        }
        break;
      }
      require(
        response?.statusCode == 200,
        missingCode,
        'Download failed (HTTP ${response?.statusCode}): $uri',
      );
      require(
        response!.contentLength <= maxBytes,
        'ARTIFACT_INVALID',
        'Download exceeds size limit.',
      );
      await rejectLinks(destination);
      await Directory(p.dirname(destination)).create(recursive: true);
      sink = File(destination).openWrite();
      var bytes = 0;
      await for (final chunk in response.timeout(const Duration(seconds: 60))) {
        bytes += chunk.length;
        require(
          bytes <= maxBytes,
          'ARTIFACT_INVALID',
          'Download exceeds size limit.',
        );
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

/// Development timing: with FLUTTER_PATCHER_TRACE=1 every external command
/// and marked phase prints its duration to stderr.
final bool _tracing = Platform.environment['FLUTTER_PATCHER_TRACE'] == '1';
final DateTime _traceStart = DateTime.now();

void trace(String label, [DateTime? since]) {
  if (!_tracing) return;
  final now = DateTime.now();
  final total = now.difference(_traceStart).inMilliseconds / 1000;
  final took = since == null
      ? ''
      : ' ${(now.difference(since).inMilliseconds / 1000).toStringAsFixed(1)}s';
  stderr.writeln('[trace ${total.toStringAsFixed(1)}s]$took $label');
}

String _traceArgs(List<String> args) {
  final shown = args
      .take(3)
      .map((a) => a.length > 40 ? '…${a.substring(a.length - 30)}' : a);
  return shown.join(' ');
}
