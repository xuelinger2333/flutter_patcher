import 'dart:convert';
import 'package:crypto/crypto.dart';
import '../core.dart';
import 'store.dart';

String digest(List<int> bytes) => sha256.convert(bytes).toString();
List<int> encode(Map<String, dynamic> value) => utf8.encode(jsonEncode(value));

/// One non-expiring operation gate per application. Recovery repeats identical
/// intent; no force-unlock/lease timeout can let a late cleaner delete new data.
class PublicationTransaction {
  PublicationTransaction(this.store, this.application);
  final PublishStore store;
  final String application;
  Future<Map<String, dynamic>> snapshot() async =>
      _decode(await store.read('catalog.json'));
  Map<String, dynamic> _decode(StoredObject? object) {
    if (object == null) {
      return {
        'schema': 1,
        'application_id': application,
        'generation': 0,
        'operations': <String, dynamic>{},
        'releases': <String, dynamic>{},
        'heads': <String, dynamic>{}
      };
    }
    final value = jsonDecode(utf8.decode(object.bytes)) as Map<String, dynamic>;
    require(
        value['schema'] == 1 &&
            value['application_id'] == application &&
            value['operations'] is Map &&
            value['releases'] is Map &&
            value['heads'] is Map,
        'PUBLISH_CATALOG_INVALID',
        'Catalog identity/schema mismatch');
    return value;
  }

  Future<Map<String, dynamic>> run(
      String operation,
      Map<String, dynamic> intent,
      Future<Map<String, dynamic>> Function(Map<String, dynamic>)
          action) async {
    require(
        RegExp(r'^[a-f0-9]{32}$').hasMatch(operation),
        'PUBLISH_CONFIG_INVALID',
        'Operation must be 32 lowercase hex characters');
    final identity = digest(encode(intent));
    final before = await store.read('catalog.json');
    final catalog = _decode(before);
    final completed = (catalog['operations'] as Map)[operation];
    if (completed != null) {
      require(completed['intent'] == identity, 'PUBLISH_CONFLICT',
          'Operation reused with different intent');
      final receipt = Map<String, dynamic>.from(completed['receipt'] as Map);
      require(
          receipt['status'] != 'rejected',
          receipt['code'] as String? ?? 'PUBLISH_CONFLICT',
          'Operation was rejected; use a fresh operation after replanning');
      return receipt;
    }
    final gate = catalog['pending'];
    if (gate != null) {
      require(
          gate['operation'] == operation && gate['intent'] == identity,
          'PUBLISH_BUSY',
          'Another operation is pending; resume it with identical inputs');
    } else {
      // Reserve space for the journal and release before uploading/deleting.
      require(
          encode(catalog).length + encode(intent).length * 3 + 65536 <
              8 * 1024 * 1024,
          'PUBLISH_CATALOG_FULL',
          'Catalog capacity reserve exhausted; no operation started');
      catalog['pending'] = {'operation': operation, 'intent': identity};
      catalog['generation'] = (catalog['generation'] as int) + 1;
      await _cas(catalog, before?.token);
    }
    final locked = await store.read('catalog.json');
    require(
        locked != null, 'PUBLISH_COMMIT_UNKNOWN', 'Catalog readback missing');
    final working = _decode(locked);
    require(
        working['pending']?['operation'] == operation &&
            working['pending']?['intent'] == identity,
        'PUBLISH_CONFLICT',
        'Operation gate changed');
    Map<String, dynamic> receipt;
    try {
      receipt = await action(working);
    } on Failure catch (error) {
      // These checks run before any side effects. Release a stale plan's gate
      // and retain its rejection so a new operation can be planned safely.
      if (!{'PUBLISH_CONFLICT', 'PUBLISH_RETENTION_STALE'}
          .contains(error.code)) {
        rethrow;
      }
      working.remove('pending');
      (working['operations'] as Map)[operation] = {
        'intent': identity,
        'receipt': {'status': 'rejected', 'code': error.code}
      };
      working['generation'] = (working['generation'] as int) + 1;
      await _cas(working, locked!.token);
      rethrow;
    }
    (working['operations'] as Map)[operation] = {
      'intent': identity,
      'receipt': receipt,
      'previous_catalog_token': locked!.token,
      'committed_generation': (working['generation'] as int) + 1
    };
    working.remove('pending');
    working['generation'] = (working['generation'] as int) + 1;
    await _cas(working, locked.token);
    return receipt;
  }

  Future<void> _cas(Map<String, dynamic> catalog, String? token) async {
    final bytes = encode(catalog);
    require(bytes.length <= 8 * 1024 * 1024, 'PUBLISH_CATALOG_FULL',
        'Catalog capacity exceeded; archive protocol needed');
    bool success;
    try {
      success = await store.write('catalog.json', bytes, token);
    } catch (_) {
      final now = await store.read('catalog.json');
      if (now != null && digest(now.bytes) == digest(bytes)) return;
      throw Failure('PUBLISH_COMMIT_UNKNOWN',
          'Commit outcome unknown; resume identical operation');
    }
    if (!success) {
      final now = await store.read('catalog.json');
      if (now != null && digest(now.bytes) == digest(bytes)) return;
      throw Failure(
          'PUBLISH_CONFLICT', 'Catalog changed; no unconditional retry');
    }
    final now = await store.read('catalog.json');
    require(
        now != null && digest(now.bytes) == digest(bytes),
        'PUBLISH_COMMIT_UNKNOWN',
        'Commit readback changed; retry identical operation');
  }
}
