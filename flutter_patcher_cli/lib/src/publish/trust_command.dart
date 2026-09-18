import 'dart:convert';
import 'dart:io';
import 'package:args/args.dart';
import 'package:path/path.dart' as p;
import '../core.dart';
import '../sdk/host.dart';
import '../crypto/signing.dart';
import 'store.dart';
import 'trust.dart';

ArgParser trustOptions() => ArgParser()
  ..addFlag('help', abbr: 'h', negatable: false)
  ..addOption('fields', help: 'Trust payload JSON, public fields only.')
  ..addOption('root-public', help: 'Immutable host root public key file.')
  ..addOption('root-private', help: 'Root seed file; sign only.')
  ..addOption('out', help: 'New signed document path.')
  ..addOption('wire', help: 'Exact signed document to publish.')
  ..addOption('store',
      help: 'Dedicated file:// or s3:// namespace for this trust scope.')
  ..addOption('cache-dir');

Future<int> trustCommand(ArgResults args) async {
  requireSupportedHost();
  require(
      args.rest.length == 1 && {'sign', 'publish'}.contains(args.rest.single),
      'USAGE_ERROR',
      'Use trust sign or trust publish.');
  String input(String name) {
    final value = args[name] as String?;
    require(value != null && value.isNotEmpty, 'TRUST_CONFIG_INVALID',
        'Missing --$name');
    return value!;
  }

  final cache = managedCache(args['cache-dir'] as String?);
  await Directory(cache).create(recursive: true);
  final work = await Directory(cache).createTemp('trust-');
  final commands = Commands(cache);
  final root = (await File(input('root-public')).readAsString()).trim();
  Future<TrustUpdate> verify(String wire, String stage) async {
    require(wire.length <= 24000, 'TRUST_INVALID', 'Trust envelope size');
    final envelope = jsonDecode(wire) as Map;
    require(envelope.length == 2, 'TRUST_INVALID', 'Trust envelope fields');
    final payload = base64Decode(envelope['payload'] as String);
    final signature = base64Decode(envelope['signature'] as String);
    final text = utf8.decode(payload);
    final update =
        TrustUpdate((jsonDecode(text) as Map).cast<String, String>());
    require(text == update.canonical && update.envelope(signature) == wire,
        'TRUST_INVALID', 'Noncanonical trust document');
    await verifyMessage(update.signingBytes, signature, root,
        p.join(work.path, stage), commands);
    return update;
  }

  if (args.rest.single == 'sign') {
    require(args['wire'] == null && args['store'] == null, 'USAGE_ERROR',
        'Sign options mixed with publish.');
    final fields = await readObject(input('fields'));
    final update = TrustUpdate(fields.cast<String, String>());
    final out = File(input('out'));
    await rejectLinks(out.path);
    require(
        !await out.exists(), 'TRUST_OUTPUT_EXISTS', 'Use a new output file.');
    final seed = (await File(input('root-private')).readAsString()).trim();
    final signature =
        await signMessage(update.signingBytes, seed, root, work.path, commands);
    await out.parent.create(recursive: true);
    await out.writeAsString(update.envelope(signature), flush: true);
    stdout.writeln(jsonEncode(
        {'status': 'trust_signed', 'revision': update.fields['revision']}));
    return 0;
  }
  require(
      args['root-private'] == null &&
          args['fields'] == null &&
          args['out'] == null,
      'USAGE_ERROR',
      'Publish does not accept private key or signing options.');
  final source = File(input('wire'));
  require(
      await source.length() <= 24000, 'TRUST_INVALID', 'Trust envelope size');
  final wire = await source.readAsString();
  final update = await verify(wire, 'new');
  final uri = Uri.parse(input('store'));
  require(uri.userInfo.isEmpty && !uri.hasQuery && !uri.hasFragment,
      'TRUST_CONFIG_INVALID', 'Store credentials must use the environment.');
  final PublishStore store = uri.scheme == 'file'
      ? FilePublishStore(uri.toFilePath())
      : S3PublishStore(uri, commands, p.join(work.path, 's3'));
  final previous = await store.read('trust.json');
  if (previous != null) {
    final oldWire = utf8.decode(previous.bytes);
    final old = await verify(oldWire, 'old');
    require(
        TrustUpdate.scopeKeys
            .every((key) => old.fields[key] == update.fields[key]),
        'TRUST_SCOPE_CONFLICT',
        'This namespace belongs to another host scope.');
    final nextRevision = int.parse(update.fields['revision']!);
    final oldRevision = int.parse(old.fields['revision']!);
    require(
        nextRevision > oldRevision ||
            nextRevision == oldRevision && oldWire == wire,
        'TRUST_REPLAY',
        'Trust revision must increase; identical retry is allowed.');
    if (oldWire == wire) {
      stdout.writeln('{"status":"trust_already_published"}');
      return 0;
    }
  }
  final bytes = utf8.encode(wire);
  final committed = await store.write('trust.json', bytes, previous?.token);
  if (!committed) {
    final actual = await store.read('trust.json');
    require(actual != null && utf8.decode(actual.bytes) == wire,
        'TRUST_CONFLICT', 'Concurrent trust update; reread before retrying.');
  }
  stdout.writeln(jsonEncode(
      {'status': 'trust_published', 'revision': update.fields['revision']}));
  return 0;
}
