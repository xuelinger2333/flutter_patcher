import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../baseline/store.dart' show serialized;
import '../core.dart';

class StoredObject {
  final Uint8List bytes;
  final String token;
  StoredObject(this.bytes, this.token);
}

/// The publication store at [uri]: a directory (`file://`) or S3.
PublishStore openPublishStore(Uri uri, Commands commands, String work) {
  require(
    uri.userInfo.isEmpty && uri.query.isEmpty && uri.fragment.isEmpty,
    'PUBLISH_CONFIG_INVALID',
    'Store URI must not contain credentials',
  );
  return uri.scheme == 'file'
      ? FilePublishStore(uri.toFilePath())
      : S3PublishStore(uri, commands, p.join(work, 's3'));
}

/// ETags are concurrency tokens, never content checksums. Null expects absence.
abstract class PublishStore {
  Future<StoredObject?> read(String name);
  Future<bool> write(String name, List<int> bytes, String? expected);
}

/// Patch files are the only objects publish writes: `<fileName>` at
/// the store's root, beside anything flutter_patcher 1.0 left there.
void publicationName(String name) => require(
  RegExp(
    r'^[1-9][0-9]{0,9}(-[A-Za-z0-9_]{1,64}-[A-Za-z0-9_]{1,64})?-'
    r'(arm64-v8a|ios-arm64)\.fptc$',
  ).hasMatch(name),
  'PUBLISH_STORE_INVALID',
  'Invalid patch file name',
);

const publicationLimit = 320 * 1024 * 1024;

class FilePublishStore implements PublishStore {
  FilePublishStore(String root) : root = p.normalize(p.absolute(root));
  final String root;
  Future<T> _locked<T>(Future<T> Function() action) =>
      serialized(root, () async {
        await rejectLinks(root);
        await Directory(root).create(recursive: true);
        final path = p.join(root, '.publish.lock');
        await rejectLinks(path);
        final lock = await File(path).open(mode: FileMode.append);
        await lock.lock(FileLock.blockingExclusive);
        try {
          return await action();
        } finally {
          await lock.unlock();
          await lock.close();
        }
      });
  Future<StoredObject?> _read(String name) async {
    publicationName(name);
    final path = p.join(root, name);
    await rejectLinks(path);
    final file = File(path);
    if (!await file.exists()) return null;
    require(
      await file.length() <= publicationLimit,
      'PUBLISH_STORE_INVALID',
      'Object exceeds limit',
    );
    final bytes = await file.readAsBytes();
    return StoredObject(bytes, sha256.convert(bytes).toString());
  }

  @override
  Future<StoredObject?> read(String name) => _read(name);
  @override
  Future<bool> write(String name, List<int> bytes, String? expected) =>
      _locked(() async {
        final old = await _read(name);
        if (old?.token != expected) return false;
        final file = File(p.join(root, name));
        await Directory(p.dirname(file.path)).create(recursive: true);
        final staging = File(temporaryName(file.path));
        await staging.writeAsBytes(bytes, flush: true);
        await staging.renameRetry(file.path);
        return true;
      });
}

/// A dedicated prefix of a bucket; publish writes patch files there.
class S3PublishStore implements PublishStore {
  S3PublishStore(this.uri, this.commands, this.work) {
    require(
      uri.scheme == 's3' &&
          uri.host.isNotEmpty &&
          uri.userInfo.isEmpty &&
          uri.query.isEmpty &&
          uri.fragment.isEmpty &&
          uri.pathSegments
              .where((s) => s.isNotEmpty)
              .every((s) => RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(s)),
      'PUBLISH_STORE_INVALID',
      'Use a dedicated S3 prefix without credentials',
    );
    require(
      uri.pathSegments.where((s) => s.isNotEmpty).isNotEmpty,
      'PUBLISH_STORE_INVALID',
      'Bucket root is not a publication namespace',
    );
  }
  final Uri uri;
  final Commands commands;
  final String work;
  String get prefix =>
      '${uri.pathSegments.where((s) => s.isNotEmpty).join('/')}/';
  Future<CommandResult> _call(String op, List<String> args) async {
    final endpoint = commands.environment['FLUTTER_PATCHER_S3_ENDPOINT'];
    if (endpoint != null) Downloads.validateUri(Uri.parse(endpoint));
    try {
      return await commands.runResult(
        'aws',
        [
          if (endpoint != null) ...['--endpoint-url', endpoint],
          's3api',
          op,
          '--bucket',
          uri.host,
          ...args,
          '--output',
          'json',
        ],
        extraEnvironment: {'AWS_PAGER': ''},
      );
    } catch (_) {
      throw Failure(
        'PUBLISH_STORE_UNAVAILABLE',
        'AWS CLI operation unavailable',
      );
    }
  }

  void _success(CommandResult r) => require(
    r.exitCode == 0,
    'PUBLISH_STORE_UNAVAILABLE',
    'S3 operation failed; conditional operations must be supported',
  );
  @override
  Future<StoredObject?> read(String name) async {
    publicationName(name);
    await Directory(work).create(recursive: true);
    final destination = temporaryName(p.join(work, 'read'));
    final max = publicationLimit;
    final result = await _call('get-object', [
      '--key',
      '$prefix$name',
      '--range',
      'bytes=0-$max',
      destination,
    ]);
    if (result.exitCode != 0 &&
        RegExp(r'\((NoSuchKey|404)\)').hasMatch(result.stderr)) {
      return null;
    }
    _success(result);
    final file = File(destination);
    try {
      require(
        await file.length() <= max,
        'PUBLISH_STORE_INVALID',
        'Object exceeds limit',
      );
      final token = (jsonDecode(result.stdout) as Map)['ETag'];
      require(
        token is String && token.isNotEmpty,
        'PUBLISH_STORE_INVALID',
        'Missing ETag',
      );
      return StoredObject(await file.readAsBytes(), token as String);
    } finally {
      if (await file.exists()) await file.deleteRetry();
    }
  }

  @override
  Future<bool> write(String name, List<int> bytes, String? expected) async {
    publicationName(name);
    await Directory(work).create(recursive: true);
    final file = File(temporaryName(p.join(work, 'upload')));
    await file.writeAsBytes(bytes, flush: true);
    try {
      final result = await _call('put-object', [
        '--key',
        '$prefix$name',
        '--body',
        file.path,
        if (expected == null) ...[
          '--if-none-match',
          '*',
        ] else ...[
          '--if-match',
          expected,
        ],
      ]);
      if (result.exitCode != 0 &&
          RegExp(r'\((PreconditionFailed|ConditionalRequestConflict)\)')
              .hasMatch(result.stderr)) {
        return false;
      }
      _success(result);
      return true;
    } finally {
      await file.deleteRetry();
    }
  }
}
