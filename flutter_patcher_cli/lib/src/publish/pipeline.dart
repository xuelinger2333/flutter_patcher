import 'dart:convert';
import 'dart:typed_data';
import 'package:path/path.dart' as p;
import '../baseline/archive.dart';
import '../baseline/manifest.dart';
import '../baseline/repository.dart';
import '../baseline/store.dart';
import '../core.dart';
import '../crypto/signing.dart';
import 'protocol.dart';
import 'transaction.dart';

/// Always fetch into a fresh cache: a local hit must not mask a missing remote baseline.
Future<Map<String, dynamic>> publicationBaseline(
    BaselineStore store, Map<String, String> fields, String work,
    {BaselineArchive? archive}) async {
  final repo = BaselineRepository(p.join(work, 'baseline-cache'), store,
      archive: archive);
  final link =
      await repo.verifyRelease(fields['flavor']!, fields['version_code']!);
  require(link['fingerprint'] == fields['fingerprint'],
      'PUBLISH_TARGET_MISMATCH', 'Release fingerprint differs');
  final root = p.join(work, 'baseline-cache', fields['fingerprint']);
  final receipt = await baselineObject(p.join(root, 'build_receipt.json'));
  require(
      receipt['application_id'] == fields['application_id'] &&
          receipt['version_code'] == fields['version_code'] &&
          receipt['public_key'] is String,
      'PUBLISH_TARGET_MISMATCH',
      'Verified host identity/public key differs');
  return {
    'receipt': receipt,
    'baseline': await verifyBaseline(root),
    'fingerprint': fields['fingerprint']
  };
}

Future<void> verifyPublicationPatch(Uint8List bytes, Map<String, String> fields,
    String publicKey, String work, Commands commands) async {
  require(bytes.length >= 146 && bytes.length <= 320 * 1024 * 1024,
      'PUBLISH_PATCH_INVALID', 'Envelope size');
  final h = ByteData.sublistView(bytes);
  require(
      h.getUint32(0) == 0x46505443 &&
          h.getUint16(4) == 1 &&
          h.getUint64(42) == bytes.length - 146 &&
          bytes
                  .sublist(6, 38)
                  .map((b) => b.toRadixString(16).padLeft(2, '0'))
                  .join() ==
              fields['fingerprint'] &&
          h.getUint32(38).toString() == fields['patch_seq'] &&
          digest(bytes.sublist(146)) ==
              bytes
                  .sublist(50, 82)
                  .map((b) => b.toRadixString(16).padLeft(2, '0'))
                  .join(),
      'PUBLISH_PATCH_INVALID',
      'Envelope identity/hash mismatch');
  await verifyMessage([...bytes.sublist(0, 82), ...bytes.sublist(146)],
      bytes.sublist(82, 146), publicKey, work, commands);
}

String scopeOf(Map<String, String> fields) => digest(utf8.encode(jsonEncode({
      for (final k in [
        'application_id',
        'channel',
        'flavor',
        'version_code',
        'abi',
        'fingerprint',
        'strategy'
      ])
        k: fields[k]
    })));

/// Matches native policy; integration vectors exercise both implementations.
void publicationPolicy(Map<String, String> f, Map? prior, int expected) {
  final revision = prior?['revision'] as int? ?? 0;
  require(expected == revision && int.parse(f['revision']!) > revision,
      'PUBLISH_CONFLICT', 'Expected/current revision mismatch');
  if (f['action'] == 'publish') {
    final seq = int.parse(f['patch_seq']!);
    final high = prior?['high_seq'] as int? ?? 0,
        floor = prior?['withdrawn_through'] as int? ?? 0;
    require(
        seq > floor &&
            (seq > high ||
                (seq == high && f['sha256'] == prior?['patch_hash'])),
        'PUBLISH_CONFLICT',
        'Patch sequence conflict or withdrawn');
  }
}

class PublicationPipeline {
  PublicationPipeline(this.transaction, this.commands, this.work);
  final PublicationTransaction transaction;
  final Commands commands;
  final String work;

  Future<Map<String, dynamic>> execute(
      {required String operation,
      required Map<String, String> fields,
      required int expectedRevision,
      required String seed,
      required String publicKey,
      required String createdAt,
      required Map<String, dynamic> baseline,
      Uint8List? patch,
      bool commit = false,
      bool pin = false}) async {
    require(
        RegExp(r'^[a-f0-9]{32}$').hasMatch(operation),
        'PUBLISH_CONFIG_INVALID',
        'Operation must be 32 lowercase hex characters');
    require(fields['strategy'] == 'bytecode', 'PUBLISH_UNSUPPORTED',
        'Production pipeline currently requires bytecode');
    require(int.tryParse(createdAt) != null && int.parse(createdAt) >= 0,
        'PUBLISH_CONFIG_INVALID', 'Stable created_at epoch seconds required');
    require(
        baseline['fingerprint'] == fields['fingerprint'] &&
            baseline['receipt']['application_id'] == fields['application_id'] &&
            baseline['receipt']['version_code'] == fields['version_code'],
        'PUBLISH_TARGET_MISMATCH',
        'Baseline target differs');
    final f = Map<String, String>.from(fields);
    final name =
        patch == null ? null : 'objects/$operation/${digest(patch)}.fptc';
    if (f['action'] == 'publish') {
      require(patch != null && name != null, 'PUBLISH_CONFIG_INVALID',
          'Patch required');
      require(
          f['sha256'] == digest(patch!) &&
              f['size'] == patch.length.toString() &&
              Uri.parse(f['url']!).path.endsWith('/$name'),
          'PUBLISH_PATCH_INVALID',
          'Payload URL/identity differs');
      await verifyPublicationPatch(
          patch,
          f,
          baseline['receipt']['public_key'] as String,
          p.join(work, 'patch-verify'),
          commands);
    } else {
      require(
          patch == null, 'PUBLISH_CONFIG_INVALID', 'Withdrawal has no payload');
    }
    final manifest = PublishManifest(f), scope = scopeOf(f);
    final signature = await signMessage(manifest.signingBytes, seed, publicKey,
        p.join(work, 'manifest-sign'), commands);
    final wire = manifest.envelope(signature);
    final intent = {
      'kind': 'publish',
      'manifest': wire,
      'expected_revision': expectedRevision,
      'created_at': createdAt,
      'pin': pin,
      'baseline': baseline
    };
    final catalog = await transaction.snapshot();
    final previous = (catalog['heads'] as Map)[scope];
    final completed = (catalog['operations'] as Map)[operation];
    final pending = catalog['pending'];
    require(
        pending == null ||
            (pending['operation'] == operation &&
                pending['intent'] == digest(encode(intent))),
        'PUBLISH_BUSY',
        'Another operation is pending or recovery inputs differ');
    if (completed != null) {
      require(
          completed['intent'] == digest(encode(intent)) &&
              completed['receipt']['status'] != 'rejected',
          'PUBLISH_CONFLICT',
          'Operation was reused or rejected; prepare a fresh operation');
    }
    if (completed == null) {
      publicationPolicy(
          f,
          previous == null
              ? null
              : (catalog['releases'] as Map)[previous] as Map,
          expectedRevision);
    }
    if (!commit) {
      return {
        'status': 'preview',
        'operation': operation,
        'scope': scope,
        'manifest_sha256': digest(utf8.encode(manifest.canonical)),
        'object': name,
        'fingerprint': f['fingerprint'],
        'revision': f['revision']
      };
    }
    return transaction.run(operation, intent, (current) async {
      final oldId = (current['heads'] as Map)[scope];
      final old =
          oldId == null ? null : (current['releases'] as Map)[oldId] as Map;
      publicationPolicy(f, old, expectedRevision);
      if (patch != null) {
        final existing = await transaction.store.read(name!);
        if (existing == null) {
          try {
            await transaction.store.write(name, patch, null);
          } catch (_) {/* Readback resolves an interrupted immutable upload. */}
        }
        final actual = await transaction.store.read(name);
        require(
            actual != null &&
                actual.bytes.length == patch.length &&
                digest(actual.bytes) == digest(patch),
            'PUBLISH_UPLOAD_FAILED',
            'Payload readback failed; resume operation');
      }
      final high = old?['high_seq'] as int? ?? 0,
          floor = old?['withdrawn_through'] as int? ?? 0;
      final withdrawn = f['action'] == 'withdraw'
          ? int.parse(f['withdraw_through_seq']!)
          : floor;
      final newFloor = withdrawn > floor ? withdrawn : floor;
      final seq = patch == null ? newFloor : int.parse(f['patch_seq']!);
      final receipt = {
        'status': 'published',
        'operation': operation,
        'scope': scope,
        'action': f['action'],
        'manifest_sha256': digest(utf8.encode(manifest.canonical)),
        'fingerprint': f['fingerprint'],
        'revision': int.parse(f['revision']!),
        'object': name,
        'sha256': f['sha256'],
        'size': patch?.length,
        'baseline_identity': baseline,
        'public_download_verified': false,
        'publisher_source': 'not_recorded',
        'patch_source': 'not_provided',
        'publication_key_sha256': digest(base64Decode(publicKey.trim()))
      };
      (current['releases'] as Map)[operation] = {
        ...receipt,
        'wire': wire,
        'created_at': int.parse(createdAt),
        'pin': pin,
        'high_seq': seq > high ? seq : high,
        'withdrawn_through': newFloor,
        'patch_hash': f['sha256'] ?? old?['patch_hash'] ?? ''
      };
      (current['heads'] as Map)[scope] = operation;
      return receipt;
    });
  }
}
