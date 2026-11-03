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
  ..addFlag('yes',
      abbr: 'y',
      negatable: false,
      help: 'Publish without asking; otherwise preview, then ask when '
          'interactive.')
  ..addOption('project',
      help: 'Application directory; default the current one.')
  ..addOption('patch',
      help: 'A patch output directory; default the project\'s latest patch.')
  ..addFlag('production',
      negatable: false, help: 'With --request: publish that request instead.')
  ..addOption('request', help: 'Advanced: a production request JSON file.')
  ..addOption('receipt', help: 'New output JSON file for the result.');

Future<int> productionPublish(ArgResults args) async {
  stdout.writeln(jsonEncode(
      {'command': 'publish', 'scope': 'production', ...await publication(args)}));
  return 0;
}

/// Runs a publish or cleanup request and returns its receipt.
Future<Map<String, dynamic>> publication(ArgResults args) async {
  requireSupportedHost();
  require(
      args.rest.isEmpty &&
          (args['request'] == null) == (args['production'] != true),
      'PUBLISH_CONFIG_INVALID',
      'Use publish [--patch DIR] [--yes], or publish --production '
      '--request FILE [--yes]');
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
    if (args['yes'] == true) {
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
      fields['sha256'] = digest(bytes);
      fields['size'] = bytes.length.toString();
      fields['path'] = 'objects/$operation/${digest(bytes)}.fptc';
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
    final seed = await File(request['private_key'] as String).readAsString(),
        publicKey = await File(request['public_key'] as String).readAsString();
    Future<Map<String, dynamic>> execute(bool commit) =>
        PublicationPipeline(transaction, commands, work.path).execute(
            operation: operation,
            fields: fields,
            expectedRevision: request['expected_revision'] as int,
            seed: seed,
            publicKey: publicKey,
            createdAt: request['created_at'].toString(),
            baseline: release.identity,
            target: release.target,
            patch: bytes,
            commit: commit,
            pin: request['pin'] == true);
    result = await execute(false);
    final what = fields['action'] == 'publish'
        ? 'patch ${fields['patch_seq']}'
        : 'withdrawal through ${fields['withdraw_through_seq']}';
    if (await confirmed(
        args,
        'Publish $what to ${fields['application_id']} ${fields['channel']} '
        'versionCode ${fields['version_code']} '
        '(revision ${fields['revision']})?')) {
      result = await execute(true);
    }
  }
  if (args['receipt'] != null) {
    final path = args['receipt'] as String;
    await rejectLinks(path);
    require(!await File(path).exists(), 'PUBLISH_CONFIG_INVALID',
        'Receipt target already exists');
    await writeObject(path, result);
  }
  return result;
}

/// The newest finished output `patch` wrote to [project]. Outputs are named
/// by creation time; one still being written has a `.pending-` suffix.
Future<String?> latestPatchOutput(String project) async {
  final patches = Directory(
      p.join(project, '.dart_tool', 'flutter_patcher', 'patches'));
  if (!await patches.exists()) return null;
  final runs = await patches
      .list()
      .where((e) =>
          e is Directory && RegExp(r'^\d+$').hasMatch(p.basename(e.path)))
      .map((e) => e.path)
      .toList();
  return runs.isEmpty ? null : (runs..sort()).last;
}

/// Publishing changes what devices install: unless --yes says so, ask
/// before committing, and only preview when no one can answer.
Future<bool> confirmed(ArgResults args, String question) async {
  if (args['yes'] == true) return true;
  if (!stdin.hasTerminal) return false;
  stderr.write('$question [y/N] ');
  return (stdin.readLineSync() ?? '').trim().toLowerCase() == 'y';
}

/// The request publishing a project's patch: its scope and sequence from
/// the patch output, the store and keys from the project, and the revision
/// that follows the store's current one.
Future<Map<String, dynamic>> projectRequest(ArgResults args) async {
  final project =
      p.absolute(args['project'] as String? ?? Directory.current.path);
  final config = await ProjectConfig.load(project);
  final directory =
      args['patch'] as String? ?? await latestPatchOutput(project);
  require(directory != null, 'PUBLISH_CONFIG_INVALID',
      'No patch to publish; run patch first or pass --patch.');
  final report = await readObject(p.join(directory!, 'patch.json'));
  final scope = report['scope'];
  require(report['status'] == 'patch_created' && scope is Map,
      'PUBLISH_CONFIG_INVALID',
      '$directory is not a patch output of this flutter_patcher.');
  final store = config.store;
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
