import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:path/path.dart' as p;

import '../core.dart';
import '../run_work.dart';
import '../sdk/host.dart';
import '../crypto/signing.dart';
import '../keys/bundle.dart';
import '../keys/keyring.dart';
import '../project.dart';
import 'store.dart';
import 'trust.dart';

ArgParser trustOptions() => ArgParser()
  ..addFlag('help', abbr: 'h', negatable: false)
  ..addOption('fields', help: 'Trust payload JSON, public fields only.')
  ..addOption(
    'project',
    help: 'Application directory whose keys to use; default the current one.',
  )
  ..addOption(
    'root-public',
    help: 'Host root public key file; default the project\'s.',
  )
  ..addOption(
    'key-file',
    help:
        'sign: a key bundle holding the root key, before '
        '${Keyring.environmentVariable}, signing.command and the key store.',
  )
  ..addOption('out', help: 'New signed document path.')
  ..addOption('wire', help: 'Exact signed document to publish.')
  ..addOption(
    'store',
    help: 'Dedicated file:// or s3:// namespace for this trust scope.',
  )
  ..addOption('cache-dir');

Future<int> trustCommand(ArgResults args) async {
  requireSupportedHost();
  require(
    args.rest.length == 1 && {'sign', 'publish'}.contains(args.rest.single),
    'USAGE_ERROR',
    'Use trust sign or trust publish.',
  );
  String input(String name) {
    final value = args[name] as String?;
    require(
      value != null && value.isNotEmpty,
      'TRUST_CONFIG_INVALID',
      'Missing --$name',
    );
    return value!;
  }

  final cache = managedCache(args['cache-dir'] as String?);
  final work = await RunWork.create(p.join(cache, 'trust'));
  try {
    final commands = Commands(cache);
    final config = await ProjectConfig.load(
      p.absolute(args['project'] as String? ?? Directory.current.path),
    );
    final root = args['root-public'] == null
        ? config.requireAnchors().root
        : (await File(args['root-public'] as String).readAsString()).trim();
    Future<TrustUpdate> verify(String wire, String stage) async {
      require(wire.length <= 24000, 'TRUST_INVALID', 'Trust envelope size');
      final envelope = jsonDecode(wire) as Map;
      require(envelope.length == 2, 'TRUST_INVALID', 'Trust envelope fields');
      final payload = base64Decode(envelope['payload'] as String);
      final signature = base64Decode(envelope['signature'] as String);
      final text = utf8.decode(payload);
      final update = TrustUpdate(
        (jsonDecode(text) as Map).cast<String, String>(),
      );
      require(
        text == update.canonical && update.envelope(signature) == wire,
        'TRUST_INVALID',
        'Noncanonical trust document',
      );
      verifyMessage(update.signingBytes, signature, root);
      return update;
    }

    if (args.rest.single == 'sign') {
      require(
        args['wire'] == null && args['store'] == null,
        'USAGE_ERROR',
        'Sign options mixed with publish.',
      );
      final fields = await readObject(input('fields'));
      final update = TrustUpdate(fields.cast<String, String>());
      final out = File(input('out'));
      await rejectLinks(out.path);
      require(
        !await out.exists(),
        'TRUST_OUTPUT_EXISTS',
        'Use a new output file.',
      );
      final signer = await Keyring.forProject(
        config,
        keyFile: args['key-file'] as String?,
      ).signer(KeyRole.root);
      final signature = await signer.sign(update.signingBytes);
      verifyMessage(update.signingBytes, signature, root);
      await out.parent.create(recursive: true);
      await out.writeAsString(update.envelope(signature), flush: true);
      stdout.writeln(
        jsonEncode({
          'status': 'trust_signed',
          'revision': update.fields['revision'],
        }),
      );
      return 0;
    }
    require(
      args['key-file'] == null && args['fields'] == null && args['out'] == null,
      'USAGE_ERROR',
      'Publish does not accept private key or signing options.',
    );
    final source = File(input('wire'));
    require(
      await source.length() <= 24000,
      'TRUST_INVALID',
      'Trust envelope size',
    );
    final wire = await source.readAsString();
    final update = await verify(wire, 'new');
    final uri = Uri.parse(input('store'));
    require(
      uri.userInfo.isEmpty && !uri.hasQuery && !uri.hasFragment,
      'TRUST_CONFIG_INVALID',
      'Store credentials must use the environment.',
    );
    final PublishStore store = uri.scheme == 'file'
        ? FilePublishStore(uri.toFilePath())
        : S3PublishStore(uri, commands, p.join(work, 's3'));
    final previous = await store.read('trust.json');
    if (previous != null) {
      final oldWire = utf8.decode(previous.bytes);
      final old = await verify(oldWire, 'old');
      require(
        TrustUpdate.scopeKeys.every(
          (key) => old.fields[key] == update.fields[key],
        ),
        'TRUST_SCOPE_CONFLICT',
        'This namespace belongs to another host scope.',
      );
      final nextRevision = int.parse(update.fields['revision']!);
      final oldRevision = int.parse(old.fields['revision']!);
      require(
        nextRevision > oldRevision ||
            nextRevision == oldRevision && oldWire == wire,
        'TRUST_REPLAY',
        'Trust revision must increase; identical retry is allowed.',
      );
      if (oldWire == wire) {
        stdout.writeln('{"status":"trust_already_published"}');
        return 0;
      }
    }
    final bytes = utf8.encode(wire);
    final committed = await store.write('trust.json', bytes, previous?.token);
    if (!committed) {
      final actual = await store.read('trust.json');
      require(
        actual != null && utf8.decode(actual.bytes) == wire,
        'TRUST_CONFLICT',
        'Concurrent trust update; reread before retrying.',
      );
    }
    stdout.writeln(
      jsonEncode({
        'status': 'trust_published',
        'revision': update.fields['revision'],
      }),
    );
    return 0;
  } finally {
    await RunWork.finish(work);
  }
}
