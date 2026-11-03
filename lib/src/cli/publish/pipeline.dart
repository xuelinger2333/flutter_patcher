import 'dart:convert';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import '../baseline/archive.dart';
import '../baseline/manifest.dart';
import '../baseline/repository.dart';
import '../baseline/split.dart';
import '../baseline/store.dart';
import '../core.dart';
import '../crypto/signing.dart';
import 'protocol.dart';
import 'transaction.dart';
import '../../publication_scope.dart';
export '../../publication_scope.dart' show scopeOf;

/// The verified baseline identity of the target release, and the target a
/// patch for it must carry. Legacy releases keep their original identity
/// shape: it is part of the intent digest of operations that may be pending.
class PublicationRelease {
  final Map<String, dynamic> identity;
  final Map<String, dynamic>? target;
  PublicationRelease(this.identity, this.target);
}

/// Always fetch into a fresh cache: a local hit must not mask a missing remote baseline.
Future<PublicationRelease> resolvePublication(
    BaselineStore store, Map<String, String> fields, String work,
    {BaselineArchive? archive}) async {
  final repo = BaselineRepository(p.join(work, 'baseline-cache'), store,
      archive: archive);
  final release = await repo.resolve(fields['flavor']!, fields['version_code']!,
      abi: fields['abi'] ?? 'arm64-v8a');
  require(release.compile['runtime_bootstrap'] != false, 'BASELINE_NOT_RELEASE',
      'Pipeline validation baseline has no runtime bootstrap and is not a release.');
  require(release.fingerprint == fields['fingerprint'],
      'PUBLISH_TARGET_MISMATCH', 'Release fingerprint differs');
  require(release.strategy == fields['strategy'], 'PUBLISH_TARGET_MISMATCH',
      'Release strategy differs');
  final receipt = release.receipt;
  require(
      receipt['application_id'] == fields['application_id'] &&
          receipt['version_code'] == fields['version_code'] &&
          receipt['public_key'] is String,
      'PUBLISH_TARGET_MISMATCH',
      'Verified host identity/public key differs');
  if (release.legacy) {
    return PublicationRelease({
      'receipt': receipt,
      'baseline': await verifyBaseline(release.compileRoot),
      'fingerprint': fields['fingerprint']
    }, release.target);
  }
  return PublicationRelease({
    'receipt': receipt,
    'compile': release.compile,
    'release': release.release,
    'fingerprint': fields['fingerprint']
  }, release.target);
}

Future<Map<String, dynamic>> publicationBaseline(
        BaselineStore store, Map<String, String> fields, String work,
        {BaselineArchive? archive}) async =>
    (await resolvePublication(store, fields, work, archive: archive)).identity;

/// The signed patch_manifest.json of a patch package, or null.
Map<String, dynamic>? patchManifest(Uint8List bytes) {
  try {
    final entry = ZipDecoder()
        .decodeBytes(bytes.sublist(146))
        .findFile('patch_manifest.json');
    final manifest = entry == null
        ? null
        : jsonDecode(utf8.decode(entry.content as List<int>));
    return manifest is Map ? Map<String, dynamic>.from(manifest) : null;
  } catch (_) {
    return null;
  }
}

/// The signed `target` of a patch package, or null when it has none.
Map<String, dynamic>? patchTarget(Uint8List bytes) {
  final target = patchManifest(bytes)?['target'];
  return target is Map ? Map<String, dynamic>.from(target) : null;
}

/// The code kind each host strategy loads.
const codeKinds = {'bytecode': 'bytecode', 'so': 'libapp'};

/// A schema 5 release accepts only patches pinned to it; a legacy release
/// (one fingerprint per release) also accepts unpinned patches.
void checkPatchTarget(Uint8List patch, String strategy,
    Map<String, dynamic> baseline, Map<String, dynamic>? expected) {
  final pinned = baseline.containsKey('release');
  if (pinned) {
    expected =
        releaseTarget(Map<String, dynamic>.from(baseline['release'] as Map));
  }
  final manifest = patchManifest(patch);
  if (manifest != null) {
    final code = manifest['code'];
    // Format 1 bytecode patches named their module `module`.
    final kind = code is Map
        ? code['kind']
        : manifest.containsKey('module')
            ? 'bytecode'
            : null;
    require(kind == codeKinds[strategy], 'PUBLISH_TARGET_MISMATCH',
        'Patch code ($kind) does not run on a $strategy host');
  }
  final actual = patchTarget(patch);
  if (actual == null) {
    require(!pinned, 'PUBLISH_TARGET_MISMATCH',
        'Patch is not pinned to a release; create it with this CLI version');
    return;
  }
  require(expected != null && canonical(actual) == canonical(expected),
      'PUBLISH_TARGET_MISMATCH', 'Patch was created for a different release');
}

/// Releases built from the same Dart sources share a fingerprint, and the
/// device keeps one patch sequence per fingerprint: a new patch must exceed
/// every sequence already published for another release of that fingerprint.
void sharedFingerprintPolicy(Map<String, String> f, Map catalog) {
  if (f['action'] != 'publish') return;
  var high = 0;
  for (final record in (catalog['releases'] as Map).values) {
    if (record is! Map || record['fingerprint'] != f['fingerprint']) continue;
    Map signed;
    try {
      signed = jsonDecode(utf8.decode(base64Decode(
          (jsonDecode(record['wire'] as String) as Map)['payload']
              as String))) as Map;
    } catch (_) {
      // A rejection here releases the operation gate; a raw error would not.
      throw Failure('PUBLISH_SEQUENCE_CONFLICT',
          'A catalog record for this fingerprint is malformed; its sequence cannot be checked');
    }
    if (signed['flavor'] == f['flavor'] &&
        signed['version_code'] == f['version_code']) {
      continue;
    }
    final seq = record['high_seq'] ?? 0;
    require(seq is int, 'PUBLISH_SEQUENCE_CONFLICT',
        'A catalog record for this fingerprint has no valid sequence');
    if (seq as int > high) high = seq;
  }
  require(int.parse(f['patch_seq']!) > high, 'PUBLISH_SEQUENCE_CONFLICT',
      'Patch sequence must exceed $high, already published for another release with this fingerprint');
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
  verifyMessage([...bytes.sublist(0, 82), ...bytes.sublist(146)],
      bytes.sublist(82, 146), publicKey);
}

/// The smallest sequence a new patch of [fingerprint] can be published with:
/// above every sequence published or withdrawn for it, in any release.
int nextSequence(Map<String, dynamic> catalog, String fingerprint) {
  var high = 0;
  for (final record in (catalog['releases'] as Map).values) {
    if (record is! Map || record['fingerprint'] != fingerprint) continue;
    for (final key in ['high_seq', 'withdrawn_through']) {
      final seq = record[key];
      if (seq is int && seq > high) high = seq;
    }
  }
  return high + 1;
}

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
      Map<String, dynamic>? target,
      Uint8List? patch,
      bool commit = false,
      bool pin = false}) async {
    require(
        RegExp(r'^[a-f0-9]{32}$').hasMatch(operation),
        'PUBLISH_CONFIG_INVALID',
        'Operation must be 32 lowercase hex characters');

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
              f['path'] == name,
          'PUBLISH_PATCH_INVALID',
          'Payload path/identity differs');
      await verifyPublicationPatch(
          patch,
          f,
          baseline['receipt']['public_key'] as String,
          p.join(work, 'patch-verify'),
          commands);
      checkPatchTarget(patch, f['strategy']!, baseline, target);
    } else {
      require(
          patch == null, 'PUBLISH_CONFIG_INVALID', 'Withdrawal has no payload');
    }
    final manifest = PublishManifest(f), scope = scopeOf(f);
    final signature = signMessage(manifest.signingBytes, seed, publicKey);
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
    // A resumed pending operation is checked inside the transaction, where a
    // rejection also releases its gate.
    final resumed = pending != null && pending['operation'] == operation;
    if (completed == null && !resumed) {
      publicationPolicy(
          f,
          previous == null
              ? null
              : (catalog['releases'] as Map)[previous] as Map,
          expectedRevision);
      sharedFingerprintPolicy(f, catalog);
    }
    if (!commit) {
      return {
        'status': 'preview',
        'operation': operation,
        'scope': scope,
        'manifest_sha256': digest(utf8.encode(manifest.canonical)),
        'object': name,
        'manifest': 'manifests/$scope.json',
        'fingerprint': f['fingerprint'],
        'revision': f['revision']
      };
    }
    final receipt = await transaction.run(operation, intent, (current) async {
      final oldId = (current['heads'] as Map)[scope];
      final old =
          oldId == null ? null : (current['releases'] as Map)[oldId] as Map;
      publicationPolicy(f, old, expectedRevision);
      sharedFingerprintPolicy(f, current);
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
    await writeHeadManifest(transaction, scope);
    return {...receipt, 'manifest': 'manifests/$scope.json'};
  }
}

/// Devices read `manifests/<scope>.json`: the exact signed head of the scope,
/// copied from the catalog after it commits. A write only moves it to a newer
/// revision, so a slower publisher cannot put an older one back.
Future<void> writeHeadManifest(
    PublicationTransaction transaction, String scope) async {
  final name = 'manifests/$scope.json';
  int revision(List<int> wire) {
    try {
      final envelope = jsonDecode(utf8.decode(wire)) as Map;
      final fields =
          jsonDecode(utf8.decode(base64Decode(envelope['payload'] as String)))
              as Map;
      return int.parse(fields['revision'] as String);
    } catch (_) {
      return 0;
    }
  }

  for (var attempt = 0; attempt < 5; attempt++) {
    final catalog = await transaction.snapshot();
    final head = (catalog['heads'] as Map)[scope];
    if (head == null) return;
    final record = (catalog['releases'] as Map)[head] as Map;
    final current = await transaction.store.read(name);
    if (current != null &&
        revision(current.bytes) >= (record['revision'] as int)) {
      return;
    }
    if (await transaction.store
        .write(name, utf8.encode(record['wire'] as String), current?.token)) {
      return;
    }
  }
  throw Failure('PUBLISH_MANIFEST_CONFLICT',
      '$name kept changing; publish again to rewrite it');
}
