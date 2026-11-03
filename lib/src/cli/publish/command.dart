import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:args/args.dart';
import 'package:path/path.dart' as p;
import '../baseline/store.dart';
import '../core.dart';
import '../sdk/host.dart';
import '../project.dart';
import '../version.dart';
import 'pipeline.dart';
import 'retention.dart';
import 'store.dart';
import 'transaction.dart';

ArgParser publishOptions() => ArgParser()
  ..addFlag('help', abbr: 'h', negatable: false)
  ..addFlag('commit',
      negatable: false, help: 'Publish; without it, preview only.')
  ..addOption('project',
      help: 'Application directory; default the current one.')
  ..addOption('patch',
      help: 'A patch output directory; default the project\'s latest patch.')
  ..addFlag('production',
      negatable: false, help: 'With --request: publish that request instead.')
  ..addOption('request', help: 'Advanced: a production request JSON file.')
  ..addOption('receipt', help: 'New output JSON file for the result.');

Future<int> productionPublish(ArgResults args) async {
  requireSupportedHost();
  require(
      args.rest.isEmpty &&
          (args['request'] == null) == (args['production'] != true),
      'PUBLISH_CONFIG_INVALID',
      'Use publish [--patch DIR] [--commit], or publish --production '
      '--request FILE [--commit]');
  final request = args['request'] == null
      ? await projectRequest(args)
      : await readObject(args['request'] as String);
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
  final store = openPublishStore(uri, commands, work.path);
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

/// The request publishing a project's patch: its scope and sequence from
/// the patch output, the store and keys from the project, and the revision
/// that follows the store's current one.
Future<Map<String, dynamic>> projectRequest(ArgResults args) async {
  final project =
      p.absolute(args['project'] as String? ?? Directory.current.path);
  final config = await ProjectConfig.load(project);
  final patches = Directory(
      p.join(project, '.dart_tool', 'flutter_patcher', 'patches'));
  // Patch outputs are named by creation time.
  final runs = await patches.exists()
      ? (await patches.list().where((e) => e is Directory).toList())
          .map((e) => e.path)
          .toList()
      : <String>[];
  final directory =
      args['patch'] as String? ?? (runs.isEmpty ? null : (runs..sort()).last);
  require(directory != null, 'PUBLISH_CONFIG_INVALID',
      'No patch to publish; run patch first or pass --patch.');
  final report = await readObject(p.join(directory!, 'patch.json'));
  final scope = report['scope'];
  require(report['status'] == 'patch_created' && scope is Map,
      'PUBLISH_CONFIG_INVALID',
      '$directory is not a patch output of this flutter_patcher.');
  String setting(String name) {
    final value = config[name];
    require(value != null, 'PUBLISH_CONFIG_INVALID',
        'Set $name in ${ProjectConfig.file}.');
    return value!;
  }

  final store = setting('store'), publicUrl = setting('public_url');
  final fields = Map<String, String>.from(scope as Map);
  final cache = managedCache(null);
  await Directory(cache).create(recursive: true);
  final work = await Directory(cache).createTemp('publish-revision-');
  int revision;
  try {
    final catalog = await PublicationTransaction(
            openPublishStore(Uri.parse(store), Commands(cache), work.path),
            fields['application_id']!)
        .snapshot();
    final head = (catalog['heads'] as Map)[scopeOf(fields)];
    revision = head == null
        ? 0
        : ((catalog['releases'] as Map)[head] as Map)['revision'] as int;
  } finally {
    await work.delete(recursive: true);
  }
  final random = Random.secure();
  return {
    'application_id': fields['application_id'],
    'store': store,
    'baseline_store': config.baselineStore,
    'public_base_url': publicUrl,
    'operation': [
      for (var i = 0; i < 16; i++)
        random.nextInt(256).toRadixString(16).padLeft(2, '0')
    ].join(),
    'expected_revision': revision,
    'created_at': DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000,
    'private_key': config.key('publisher', private: true),
    'public_key': config.key('publisher'),
    'patch': p.join(directory, 'patch.fptc'),
    'fields': {
      ...fields,
      'schema': '1',
      'key_id': 'release',
      'minPluginVersion': packageVersion,
      'revision': '${revision + 1}',
      'action': 'publish',
      'patch_seq': '${report['patch_seq']}',
    },
  };
}
