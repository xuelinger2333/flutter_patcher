import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../core.dart';
import '../keys/keyring.dart';
import '../patch/outputs.dart';
import '../patch/package.dart';
import '../project.dart';
import '../run_work.dart';
import '../sdk/host.dart';
import '../../patch_file.dart';
import 'seal.dart';
import 'store.dart';

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
        'Write a withdrawal for that patch\'s host instead: devices that '
        'apply it drop their patch and run the installed version.',
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
        'File sequence; default the current Unix time in seconds. It must be '
        'above the sequence of the file the store holds.',
  )
  ..addOption('receipt', help: 'New output JSON file for the result.');

Future<int> publishCommand(ArgResults args) async {
  stdout.writeln(
    jsonEncode({'command': 'publish', ...await publication(args)}),
  );
  return 0;
}

/// Seals a patch output's draft, or a withdrawal of its host, numbered now,
/// as the patch file devices take and writes it to the project's store as
/// `<fileName>`, replacing the file there only with a newer one.
Future<Map<String, dynamic>> publication(ArgResults args) async {
  requireSupportedHost();
  require(
    args.rest.isEmpty,
    'PUBLISH_CONFIG_INVALID',
    'Use publish [--patch DIR] [--withdraw] [--seq N] [--yes]',
  );
  final receipt = args['receipt'] as String?;
  if (receipt != null) await _requireNew(receipt);
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
  final scope = report['scope'], patchKey = report['patch_key'];
  require(
    outputStatuses.contains(report['status']) &&
        scope is Map &&
        patchKey is String,
    'PATCH_BASELINE_INCOMPATIBLE',
    '$directory is not a patch output of this flutter_patcher; patch again.',
  );
  final withdraw =
      args['withdraw'] == true || report['status'] == 'withdrawal_created';
  final host = Map<String, String>.from(scope as Map);
  final name = patchFileName(host);
  final seq = args['seq'] == null
      ? sequenceNow()
      : int.tryParse(args['seq'] as String) ?? 0;
  checkSeq(seq);
  final signer = patchKey == '-'
      ? null
      : await Keyring(
          patchKey as String,
          keyFile: args['key-file'] as String?,
          command: config.signingCommand,
        ).signer();
  final bytes = await sealOutputFile(
    directory,
    host['fingerprint']!,
    withdrawal: withdraw,
    signer: signer,
    seq: seq,
  );
  final cache = managedCache(null);
  await Directory(cache).create(recursive: true);
  final work = await RunWork.create(p.join(cache, 'publish'));
  final Map<String, dynamic> result;
  try {
    final store = openPublishStore(
      Uri.parse(config.store),
      Commands(cache),
      work,
    );
    final existing = await store.read(name);
    PatchHeader? current;
    try {
      current = existing == null ? null : PatchHeader.parse(existing.bytes);
    } on FormatException {
      throw Failure(
        'PUBLISH_STORE_INVALID',
        'The store holds $name, which is not a patch file; remove it.',
      );
    }
    final summary = {
      'action': withdraw ? 'withdraw' : 'publish',
      'file': name,
      'store': config.store,
      'signed': signer != null,
    };
    if (current != null && current.fingerprint == host['fingerprint']) {
      // A sequence changes the payload too: compare the drafts it carries.
      final same = withdraw
          ? current.withdrawal
          : !current.withdrawal &&
                sha256
                        .convert(
                          (await sealPatch(
                            await PatchDraft.read(directory),
                            seq: current.seq,
                          )).sublist(patchHeaderSize),
                        )
                        .toString() ==
                    current.payloadSha256;
      if (same) {
        return {...summary, 'status': 'already_published', 'seq': current.seq};
      }
    }
    require(
      current == null || seq > current.seq,
      'PUBLISH_SEQUENCE_CONFLICT',
      'The store holds $name numbered ${current?.seq}, which devices may '
          'have taken already; this one would be $seq. Check this '
          'computer\'s clock, or publish with --seq ${(current?.seq ?? 0) + 1}.',
    );
    if (!await confirmed(
      args,
      '${withdraw ? 'Withdraw the patch of' : 'Publish'} $name as $seq '
      'to ${config.store}?',
    )) {
      return {...summary, 'status': 'preview', 'seq': seq};
    }
    require(
      await store.write(name, bytes, existing?.token),
      'PUBLISH_CONFLICT',
      '$name changed in the store while publishing; publish again.',
    );
    result = {...summary, 'status': 'published', 'seq': seq};
  } finally {
    await RunWork.finish(work);
  }
  final store = Uri.parse(config.store);
  if (store.scheme == 'file' && !config.urlIsLocal) {
    stderr.writeln(
      'Devices see this file once it is at ${config.url}/$name: upload '
      '${p.join(store.toFilePath(), name)} there.',
    );
  }
  if (receipt != null) {
    await _requireNew(receipt);
    await writeObject(receipt, result);
  }
  return result;
}

Future<void> _requireNew(String path) async {
  await rejectLinks(path);
  require(
    !await File(path).exists(),
    'PUBLISH_CONFIG_INVALID',
    'Receipt target already exists',
  );
}

/// Publishing changes what devices install: unless --yes says so, ask
/// before committing, and only preview when no one can answer.
Future<bool> confirmed(ArgResults args, String question) async {
  if (args['yes'] == true) return true;
  if (!stdin.hasTerminal) return false;
  stderr.write('$question [y/N] ');
  return (stdin.readLineSync() ?? '').trim().toLowerCase() == 'y';
}
