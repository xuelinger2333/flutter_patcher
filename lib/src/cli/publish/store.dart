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

/// ETags are concurrency tokens, never content checksums. Null expects absence.
abstract class PublishStore {
  Future<StoredObject?> read(String name);
  Future<bool> write(String name, List<int> bytes, String? expected);
  Future<void> delete(String name);
  Future<List<String>> list();
}

void publicationName(String name) => require(
    name == 'catalog.json' ||
        name == 'trust.json' ||
        RegExp(r'^objects/[a-f0-9]{32}/[a-f0-9]{64}\.fptc$').hasMatch(name),
    'PUBLISH_STORE_INVALID',
    'Invalid publication object name');

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
        await file.length() <=
            (name == 'catalog.json'
                ? 8 * 1024 * 1024
                : name == 'trust.json'
                    ? 24000
                    : 320 * 1024 * 1024),
        'PUBLISH_STORE_INVALID',
        'Object exceeds limit');
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
  @override
  Future<void> delete(String name) => _locked(() async {
        require(name != 'catalog.json' && name != 'trust.json',
            'PUBLISH_STORE_INVALID', 'Cannot delete catalog');
        if (await _read(name) != null) {
          await File(p.join(root, name)).deleteRetry();
        }
      });
  @override
  Future<List<String>> list() async {
    await rejectLinks(root);
    if (!await Directory(root).exists()) return [];
    final result = <String>[];
    await for (final entry
        in Directory(root).list(recursive: true, followLinks: false)) {
      require(
          entry is! Link, 'PUBLISH_STORE_INVALID', 'Store contains symlink');
      final name = p.relative(entry.path, from: root).replaceAll('\\', '/');
      if (entry is File && name != '.publish.lock') {
        publicationName(name);
        result.add(name);
      }
    }
    return result;
  }
}

/// A dedicated application namespace; only this protocol may write to it.
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
        'Use a dedicated S3 prefix without credentials');
    require(uri.pathSegments.where((s) => s.isNotEmpty).isNotEmpty,
        'PUBLISH_STORE_INVALID', 'Bucket root is not a publication namespace');
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
      return await commands.runResult('aws', [
        if (endpoint != null) ...['--endpoint-url', endpoint],
        's3api',
        op,
        '--bucket',
        uri.host,
        ...args,
        '--output',
        'json',
      ], extraEnvironment: {
        'AWS_PAGER': ''
      });
    } catch (_) {
      throw Failure(
          'PUBLISH_STORE_UNAVAILABLE', 'AWS CLI operation unavailable');
    }
  }

  void _success(CommandResult r) => require(
      r.exitCode == 0,
      'PUBLISH_STORE_UNAVAILABLE',
      'S3 operation failed; conditional operations must be supported');
  @override
  Future<StoredObject?> read(String name) async {
    publicationName(name);
    await Directory(work).create(recursive: true);
    final destination = temporaryName(p.join(work, 'read'));
    final max = name == 'catalog.json'
        ? 8 * 1024 * 1024
        : name == 'trust.json'
            ? 24000
            : 320 * 1024 * 1024;
    final result = await _call('get-object',
        ['--key', '$prefix$name', '--range', 'bytes=0-$max', destination]);
    if (result.exitCode != 0 &&
        RegExp(r'\((NoSuchKey|404)\)').hasMatch(result.stderr)) {
      return null;
    }
    _success(result);
    final file = File(destination);
    try {
      require(await file.length() <= max, 'PUBLISH_STORE_INVALID',
          'Object exceeds limit');
      final token = (jsonDecode(result.stdout) as Map)['ETag'];
      require(token is String && token.isNotEmpty, 'PUBLISH_STORE_INVALID',
          'Missing ETag');
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
          '*'
        ] else ...[
          '--if-match',
          expected
        ]
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

  @override
  Future<void> delete(String name) async {
    publicationName(name);
    require(name != 'catalog.json' && name != 'trust.json',
        'PUBLISH_STORE_INVALID', 'Cannot delete catalog');
    _success(await _call('delete-object', ['--key', '$prefix$name']));
  }

  @override
  Future<List<String>> list() async {
    final names = <String>[];
    final seen = <String>{};
    String? cursor;
    do {
      final result = await _call('list-objects-v2', [
        '--prefix',
        prefix,
        '--no-paginate',
        if (cursor != null) ...['--continuation-token', cursor]
      ]);
      _success(result);
      final page = jsonDecode(result.stdout) as Map;
      for (final row in (page['Contents'] as List? ?? [])) {
        final key = row['Key'] as String;
        require(key.startsWith(prefix), 'PUBLISH_STORE_INVALID',
            'Wrong listing prefix');
        final name = key.substring(prefix.length);
        publicationName(name);
        names.add(name);
      }
      cursor = page['IsTruncated'] == true
          ? page['NextContinuationToken'] as String?
          : null;
      require(
          page['IsTruncated'] != true || (cursor != null && seen.add(cursor)),
          'PUBLISH_STORE_INVALID',
          'Invalid pagination token');
    } while (cursor != null);
    return names;
  }
}
