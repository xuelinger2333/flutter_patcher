import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:args/args.dart';
import 'package:path/path.dart' as p;

import '../baseline/store.dart';
import '../core.dart';
import '../keys/bundle.dart';
import '../keys/keyring.dart';
import '../patch/package.dart';
import '../sdk/host.dart';
import '../project.dart';
import '../run_work.dart';
import '../version.dart';
import 'pipeline.dart';
import 'retention.dart';
import '../keys/signer.dart';
import 'store.dart';
import 'transaction.dart';

ArgParser publishOptions() => ArgParser()
  ..addFlag('help', abbr: 'h', negatable: false)
  ..addFlag(
    'yes',
    abbr: 'y',
    negatable: false,
    help:
        'Publish without asking; otherwise preview, then ask when '
        'interactive.',
  )
  ..addOption(
    'project',
    help: 'Application directory; default the current one.',
  )
  ..addOption(
    'patch',
    help: 'A patch output directory; default the project\'s latest patch.',
  )
  ..addFlag(
    'withdraw',
    negatable: false,
    help:
        'Withdraw that patch\'s release instead: devices remove its '
        'patches when the app next applies updates.',
  )
  ..addOption(
    'through',
    help:
        'With --withdraw: the highest patch sequence to withdraw; '
        'default the latest published.',
  )
  ..addFlag(
    'production',
    negatable: false,
    help: 'With --request: publish that request instead.',
  )
  ..addOption(
    'key-file',
    help:
        'A key bundle to sign with before ${Keyring.environmentVariable}, '
        'signing.command and the key store.',
  )
  ..addOption(
    'seq',
    help:
        'Publication sequence; default the published high-water mark plus one.',
  )
  ..addOption('request', help: 'Advanced: a production request JSON file.')
  ..addOption('receipt', help: 'New output JSON file for the result.');

Future<int> productionPublish(ArgResults args) async {
  stdout.writeln(
    jsonEncode({
      'command': 'publish',
      'scope': 'production',
      ...await publication(args),
    }),
  );
  return 0;
}

/// Runs a publish or cleanup request and returns its receipt. With [onlyNew]
/// a draft published before in its release, even if withdrawn or replaced
/// since, is not published again.
Future<Map<String, dynamic>> publication(
  ArgResults args, {
  bool onlyNew = false,
}) async {
  requireSupportedHost();
  require(
    args.rest.isEmpty &&
        (args['request'] == null) == (args['production'] != true),
    'PUBLISH_CONFIG_INVALID',
    'Use publish [--patch DIR] [--withdraw [--through SEQ]] [--yes], or '
        'publish --production --request FILE [--yes]',
  );
  require(
    args['request'] == null || args['withdraw'] != true,
    'PUBLISH_CONFIG_INVALID',
    'A request file sets its own action; drop --withdraw.',
  );
  require(
    args['seq'] == null ||
        (args['withdraw'] != true && args['request'] == null),
    'PUBLISH_CONFIG_INVALID',
    '--seq is for publishing a draft; production requests set fields.patch_seq.',
  );
  final project = args['request'] == null
      ? p.absolute(args['project'] as String? ?? Directory.current.path)
      : null;
  final request = project == null
      ? await readObject(args['request'] as String)
      : await resumableRequest(project) ?? await projectRequest(args);
  require(
    request['kind'] == null || {'publish', 'cleanup'}.contains(request['kind']),
    'PUBLISH_CONFIG_INVALID',
    'Unknown request kind',
  );
  if (args['receipt'] != null) {
    final path = args['receipt'] as String;
    await rejectLinks(path);
    require(
      !await File(path).exists(),
      'PUBLISH_CONFIG_INVALID',
      'Receipt target already exists',
    );
  }
  final application = request['application_id'] as String;
  require(
    RegExp(r'^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$')
        .hasMatch(application),
    'PUBLISH_CONFIG_INVALID',
    'Invalid application identity',
  );
  final cache = managedCache(request['cache_dir'] as String?);
  await rejectLinks(cache);
  await Directory(cache).create(recursive: true);
  final work = await RunWork.create(p.join(cache, 'publish'));
  Map<String, dynamic> result;
  try {
    final commands = Commands(cache);
    final store = openPublishStore(
      Uri.parse(request['store'] as String),
      commands,
      work,
    );
    final transaction = PublicationTransaction(store, application);
    final operation = request['operation'] as String;
    if (request['kind'] == 'cleanup') {
      final retention = PublicationRetention(transaction);
      if (args['yes'] == true) {
        require(
          request['approved_plan'] is String,
          'PUBLISH_CONFIG_INVALID',
          'Explicit approved_plan file required for cleanup commit',
        );
        result = await retention.execute(
          operation,
          await readObject(request['approved_plan'] as String),
        );
      } else {
        result = retention.plan(
          await transaction.snapshot(),
          request['cutoff'] as int,
        );
      }
    } else {
      final fields = Map<String, String>.from(request['fields'] as Map);
      require(
        fields['application_id'] == application,
        'PUBLISH_CONFIG_INVALID',
        'Application differs from fields',
      );
      result = await _publish(
        args,
        project,
        request,
        fields,
        transaction,
        commands,
        work,
        onlyNew,
      );
    }
  } finally {
    await RunWork.finish(work);
  }
  if (args['receipt'] != null) {
    final path = args['receipt'] as String;
    await rejectLinks(path);
    require(
      !await File(path).exists(),
      'PUBLISH_CONFIG_INVALID',
      'Receipt target already exists',
    );
    await writeObject(path, result);
  }
  return result;
}

/// Numbers and seals the request's patch draft, unless that draft is
/// already the release's latest patch, and publishes it or the request's
/// withdrawal with the project's keys.
Future<Map<String, dynamic>> _publish(
  ArgResults args,
  String? project,
  Map<String, dynamic> request,
  Map<String, String> fields,
  PublicationTransaction transaction,
  Commands commands,
  String work,
  bool onlyNew,
) async {
  final operation = request['operation'] as String;
  final baselineUri = Uri.parse(request['baseline_store'] as String);
  final uri = Uri.parse(request['store'] as String);
  if (uri.scheme == 'file' && baselineUri.scheme == 'file') {
    final a = p.normalize(p.absolute(uri.toFilePath())),
        b = p.normalize(p.absolute(baselineUri.toFilePath()));
    require(
      a != b && !p.isWithin(a, b) && !p.isWithin(b, a),
      'PUBLISH_CONFIG_INVALID',
      'Publication and baseline namespaces must not overlap',
    );
  }
  final release = await resolvePublication(
    BaselineStore.open(baselineUri, commands),
    fields,
    work,
  );
  final keyring = Keyring.forProject(
    await ProjectConfig.load(
      p.absolute(args['project'] as String? ?? Directory.current.path),
    ),
    keyFile: args['key-file'] as String?,
  );
  PatchDraft? draft;
  Signer? patchSigner;
  final specified = fields.remove('patch_seq');
  final sequence = specified == null ? null : int.tryParse(specified);
  require(
    specified == null ||
        (sequence != null && sequence > 0 && sequence <= 0xffffffff),
    'PUBLISH_SEQUENCE_CONFLICT',
    'Sequence must be between 1 and 4294967295.',
  );
  if (fields['action'] == 'publish') {
    final source = request['patch'] as String?;
    require(source != null, 'PUBLISH_CONFIG_INVALID', 'Patch required');
    draft = await PatchDraft.read(source!);
    require(
      fields['strategy'] != 'bytecode' ||
          release.identity['receipt']['module_identity'] == 1,
      'PATCH_BASELINE_INCOMPATIBLE',
      'Rebuild this bytecode host for publication-time sequences.',
    );
    final catalog = await transaction.snapshot();
    final scope = scopeOf(fields);
    final id = (catalog['heads'] as Map)[scope];
    final head = id == null ? null : (catalog['releases'] as Map)[id] as Map;
    if (head != null &&
        head['draft_sha256'] == draft.digest &&
        !awaitsRequest(catalog, request)) {
      require(
        sequence == null || sequence == head['high_seq'],
        'PUBLISH_SEQUENCE_CONFLICT',
        'This draft is already published with another sequence.',
      );
      return {
        'status': 'already_published',
        'operation': id,
        'scope': scope,
        'patch_seq': head['high_seq'],
        'revision': head['revision'],
        'manifest': 'manifests/$scope.json',
      };
    }
    final digest = draft.digest;
    final earlier = (catalog['releases'] as Map).values.cast<Map>().where(
      (record) => record['scope'] == scope && record['draft_sha256'] == digest,
    );
    if (onlyNew && earlier.isNotEmpty && !awaitsRequest(catalog, request)) {
      return {
        'status': 'published_before',
        'scope': scope,
        'patch_seq': earlier
            .map((record) => record['patch_seq'] as int)
            .reduce(max),
      };
    }
    final signer = patchSigner = await keyring.signer(KeyRole.patch);
    require(
      signer.publicKey == (release.identity['receipt'] as Map)['public_key'],
      'KEYS_MISMATCH',
      'This release was built with another patch key than the project\'s.',
    );
  }
  final publisher = await keyring.signer(KeyRole.publisher);
  final pipeline = PublicationPipeline(transaction, commands, work);
  Future<Map<String, dynamic>> execute(bool commit) => draft != null
      ? pipeline.publishDraft(
          operation: operation,
          fields: fields,
          expectedRevision: request['expected_revision'] as int,
          signer: publisher,
          patchSigner: patchSigner!,
          createdAt: request['created_at'].toString(),
          baseline: release.identity,
          target: release.target,
          draft: draft,
          sequence: sequence,
          commit: commit,
          pin: request['pin'] == true,
        )
      : pipeline.execute(
          operation: operation,
          fields: fields,
          expectedRevision: request['expected_revision'] as int,
          signer: publisher,
          createdAt: request['created_at'].toString(),
          baseline: release.identity,
          target: release.target,
          commit: commit,
          pin: request['pin'] == true,
        );
  final preview = await execute(false);
  final what = fields['action'] == 'publish'
      ? 'patch ${preview['patch_seq']}'
      : 'withdrawal through ${fields['withdraw_through_seq']}';
  if (fields['action'] == 'withdraw') {
    stderr.writeln(
      'Devices that apply this withdrawal remove patches through '
      '${fields['withdraw_through_seq']} and run the installed version from '
      'their next cold start. To return to an earlier patch instead, '
      'publish its output again: publish --patch <its directory>.',
    );
  }
  if (!await confirmed(
    args,
    'Publish $what to ${fields['application_id']} ${fields['channel']} '
    'versionCode ${fields['version_code']}?',
  )) {
    return preview;
  }
  // A commit that stops midway resumes only with this exact request: sealing
  // and signing its draft again give the same bytes.
  if (project != null) await writeObject(pendingRequest(project), request);
  final result = await execute(true);
  if (project != null) await File(pendingRequest(project)).delete();
  return result;
}

/// Where a project's publication waits while it commits.
String pendingRequest(String project) =>
    p.join(project, '.dart_tool', 'flutter_patcher', 'publish-pending.json');

/// The saved request of a publication that stopped while it committed, when
/// its store still waits for it: only that exact request can finish it, and
/// no other can run until it does. A saved request the store no longer waits
/// for is discarded.
Future<Map<String, dynamic>?> resumableRequest(String project) async {
  final file = File(pendingRequest(project));
  if (!await file.exists()) return null;
  final saved = await readObject(file.path);
  final cache = managedCache(null);
  await Directory(cache).create(recursive: true);
  final work = await RunWork.create(p.join(cache, 'publish'));
  Map<String, dynamic> catalog;
  try {
    catalog = await PublicationTransaction(
      openPublishStore(
        Uri.parse(saved['store'] as String),
        Commands(cache),
        work,
      ),
      saved['application_id'] as String,
    ).snapshot();
  } finally {
    await RunWork.finish(work);
  }
  if (awaitsRequest(catalog, saved)) {
    stderr.writeln(
      'Resuming the publication interrupted at operation '
      '${saved['operation']}; run publish again afterwards for anything else.',
    );
    return saved;
  }
  await file.delete();
  return null;
}

/// Whether [catalog]'s operation gate waits for [request].
bool awaitsRequest(Map catalog, Map request) =>
    (catalog['pending'] as Map?)?['operation'] == request['operation'];

/// The newest finished output `patch` wrote to [project]. Outputs are named
/// by creation time; one still being written has a `.pending-` suffix.
Future<String?> latestPatchOutput(String project) async {
  final patches = Directory(
    p.join(project, '.dart_tool', 'flutter_patcher', 'patches'),
  );
  if (!await patches.exists()) return null;
  final runs = await patches
      .list()
      .where(
        (e) => e is Directory && RegExp(r'^\d+$').hasMatch(p.basename(e.path)),
      )
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

/// Devices accept only a revision at or above the last one they saw. Taking
/// it from the clock keeps it rising when catalog.json is lost and the count
/// starts over, so publishing again with a higher --seq still reaches them.
int nextRevision(int current, [DateTime? now]) =>
    max(current + 1, (now ?? DateTime.now()).millisecondsSinceEpoch ~/ 1000);

/// The request publishing a project's patch draft: its scope from the patch
/// output, the store from the project, and a revision above the store's
/// current one. With --withdraw, the request withdraws that scope's
/// patches through --through, or through the latest published one.
Future<Map<String, dynamic>> projectRequest(ArgResults args) async {
  final withdraw = args['withdraw'] == true;
  require(
    args['through'] == null || withdraw,
    'PUBLISH_CONFIG_INVALID',
    '--through needs --withdraw.',
  );
  final project = p.absolute(
    args['project'] as String? ?? Directory.current.path,
  );
  final config = await ProjectConfig.load(project);
  final directory =
      args['patch'] as String? ?? await latestPatchOutput(project);
  require(
    directory != null,
    'PUBLISH_CONFIG_INVALID',
    'No patch to publish; run patch first or pass --patch.',
  );
  final report = await readObject(p.join(directory!, 'patch.json'));
  final scope = report['scope'];
  require(
    report['status'] == 'patch_created' &&
        scope is Map &&
        report['draft_sha256'] is String,
    'PUBLISH_CONFIG_INVALID',
    '$directory is not a patch output of this flutter_patcher.',
  );
  final store = config.store;
  final fields = Map<String, String>.from(scope as Map);
  final cache = managedCache(null);
  await Directory(cache).create(recursive: true);
  final work = await RunWork.create(p.join(cache, 'publish'));
  Map? head;
  try {
    final catalog = await PublicationTransaction(
      openPublishStore(Uri.parse(store), Commands(cache), work),
      fields['application_id']!,
    ).snapshot();
    final id = (catalog['heads'] as Map)[scopeOf(fields)];
    head = id == null ? null : (catalog['releases'] as Map)[id] as Map;
  } finally {
    await RunWork.finish(work);
  }
  final revision = head?['revision'] as int? ?? 0;
  final action = withdraw
      ? withdrawal(head, args['through'] as String?)
      : {'action': 'publish'};
  final random = Random.secure();
  return {
    'application_id': fields['application_id'],
    'store': store,
    'baseline_store': config.baselineStore,
    'operation': [
      for (var i = 0; i < 16; i++)
        random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ].join(),
    'expected_revision': revision,
    'created_at': DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000,
    if (!withdraw) 'patch': directory,
    'fields': {
      ...fields,
      'schema': '1',
      'key_id': 'release',
      'minPluginVersion': packageVersion,
      'revision': '${nextRevision(revision)}',
      ...action,
      if (args['seq'] != null) 'patch_seq': args['seq'] as String,
    },
  };
}

/// The fields withdrawing a scope whose current catalog record is [head]:
/// through [through], or through the highest sequence published for it.
/// Only a published sequence above the current floor can be withdrawn.
Map<String, String> withdrawal(Map? head, String? through) {
  final high = head?['high_seq'] as int? ?? 0,
      floor = head?['withdrawn_through'] as int? ?? 0;
  require(
    high > floor,
    'PUBLISH_CONFIG_INVALID',
    floor == 0
        ? 'Nothing to withdraw: no patch is published for this release.'
        : 'Nothing to withdraw: this release is withdrawn through $floor.',
  );
  final seq = through == null ? high : int.tryParse(through);
  require(
    seq != null && seq > floor && seq <= high,
    'PUBLISH_CONFIG_INVALID',
    'Withdraw through a sequence above $floor, up to the latest published $high.',
  );
  return {'action': 'withdraw', 'withdraw_through_seq': '$seq'};
}
