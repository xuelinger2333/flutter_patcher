import 'dart:convert';
import 'dart:io';
import 'package:args/args.dart';
import 'package:path/path.dart' as p;
import '../baseline/store.dart';
import '../core.dart';
import '../sdk/host.dart';
import 'pipeline.dart';
import 'retention.dart';
import 'store.dart';
import 'transaction.dart';

Future<int> productionPublish(ArgResults args) async {
  requireSupportedHost();
  require(
      !['action', 'port', 'patch', 'version-code'].any(args.wasParsed),
      'PUBLISH_CONFIG_INVALID',
      'Mock options cannot be combined with --production; use request fields');
  require(
      args.rest.isEmpty && args['request'] != null && args['out'] == null,
      'PUBLISH_CONFIG_INVALID',
      'Use --production --request FILE; --out is mock-only');
  final request = await readObject(args['request'] as String);
  require(
      request['kind'] == null ||
          {'publish', 'cleanup'}.contains(request['kind']),
      'PUBLISH_CONFIG_INVALID',
      'Unknown request kind');
  if (args['receipt'] != null) {
    final path = args['receipt'] as String;
    await rejectLinks(path);
    require(!await File(path).exists(), 'PUBLISH_CONFIG_INVALID',
        'Receipt target already exists');
  }
  final application = request['application_id'] as String;
  require(
      RegExp(r'^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$')
          .hasMatch(application),
      'PUBLISH_CONFIG_INVALID',
      'Invalid application identity');
  final cache = managedCache(request['cache_dir'] as String?);
  await rejectLinks(cache);
  await Directory(cache).create(recursive: true);
  final work = await Directory(cache).createTemp('publish-');
  final commands = Commands(cache);
  final uri = Uri.parse(request['store'] as String);
  require(uri.userInfo.isEmpty && uri.query.isEmpty && uri.fragment.isEmpty,
      'PUBLISH_CONFIG_INVALID', 'Store URI must not contain credentials');
  final PublishStore store = uri.scheme == 'file'
      ? FilePublishStore(uri.toFilePath())
      : S3PublishStore(uri, commands, p.join(work.path, 's3'));
  final transaction = PublicationTransaction(store, application);
  final operation = request['operation'] as String;
  Map<String, dynamic> result;
  if (request['kind'] == 'cleanup') {
    final retention = PublicationRetention(transaction);
    if (args['commit'] == true) {
      require(request['approved_plan'] is String, 'PUBLISH_CONFIG_INVALID',
          'Explicit approved_plan file required for cleanup commit');
      result = await retention.execute(
          operation, await readObject(request['approved_plan'] as String));
    } else {
      result = retention.plan(
          await transaction.snapshot(), request['cutoff'] as int);
    }
  } else {
    final fields = Map<String, String>.from(request['fields'] as Map);
    require(fields['application_id'] == application, 'PUBLISH_CONFIG_INVALID',
        'Application differs from fields');
    final source = request['patch'] as String?;
    if (source != null) {
      await rejectLinks(source);
      require(await File(source).length() <= 320 * 1024 * 1024,
          'PUBLISH_PATCH_INVALID', 'Patch too large');
    }
    final bytes = source == null ? null : await File(source).readAsBytes();
    if (bytes != null) {
      final direct = request['download_url'] as String?;
      final base = Uri.parse(direct ?? request['public_base_url'] as String);
      require(
          base.scheme == 'https' &&
              base.userInfo.isEmpty &&
              (direct != null || !base.hasQuery) &&
              !base.hasFragment,
          'PUBLISH_CONFIG_INVALID',
          'Public base must be HTTPS without credentials/query');
      fields['sha256'] = digest(bytes);
      fields['size'] = bytes.length.toString();
      fields['url'] = direct ??
          '${base.toString().replaceFirst(RegExp(r'/$'), '')}/objects/$operation/${digest(bytes)}.fptc';
    }
    final baselineUri = Uri.parse(request['baseline_store'] as String);
    if (uri.scheme == 'file' && baselineUri.scheme == 'file') {
      final a = p.normalize(p.absolute(uri.toFilePath())),
          b = p.normalize(p.absolute(baselineUri.toFilePath()));
      require(
          a != b && !p.isWithin(a, b) && !p.isWithin(b, a),
          'PUBLISH_CONFIG_INVALID',
          'Publication and baseline namespaces must not overlap');
    }
    final release = await resolvePublication(
        BaselineStore.open(baselineUri, commands), fields, work.path);
    for (final key in ['private_key', 'public_key']) {
      await rejectLinks(request[key] as String);
    }
    result = await PublicationPipeline(transaction, commands, work.path)
        .execute(
            operation: operation,
            fields: fields,
            expectedRevision: request['expected_revision'] as int,
            seed: await File(request['private_key'] as String).readAsString(),
            publicKey:
                await File(request['public_key'] as String).readAsString(),
            createdAt: request['created_at'].toString(),
            baseline: release.identity,
            target: release.target,
            patch: bytes,
            commit: args['commit'] == true,
            pin: request['pin'] == true);
  }
  if (args['receipt'] != null) {
    final path = args['receipt'] as String;
    await rejectLinks(path);
    require(!await File(path).exists(), 'PUBLISH_CONFIG_INVALID',
        'Receipt target already exists');
    await writeObject(path, result);
  }
  stdout.writeln(
      jsonEncode({'command': 'publish', 'scope': 'production', ...result}));
  return 0;
}
