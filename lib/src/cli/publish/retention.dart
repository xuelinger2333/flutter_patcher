import '../core.dart';
import 'transaction.dart';

/// External baselines are always pinned: legacy writers do not share our gate.
class PublicationRetention {
  PublicationRetention(this.transaction);
  final PublicationTransaction transaction;

  Map<String, dynamic> plan(Map<String, dynamic> catalog, int cutoff) {
    require(cutoff >= 0, 'PUBLISH_CONFIG_INVALID', 'Invalid retention cutoff');
    final heads = (catalog['heads'] as Map).values.toSet();
    final candidates = <Map<String, dynamic>>[];
    for (final entry in (catalog['releases'] as Map).entries) {
      final row = entry.value as Map;
      if (row['object'] != null &&
          row['deleted'] != true &&
          row['pin'] != true &&
          !heads.contains(entry.key) &&
          (row['created_at'] as int) < cutoff) {
        candidates.add({
          'release': entry.key,
          'object': row['object'],
          'sha256': row['sha256'],
          'size': row['size']
        });
      }
    }
    candidates.sort(
        (a, b) => (a['release'] as String).compareTo(b['release'] as String));
    return {
      'application_id': catalog['application_id'],
      'cutoff': cutoff,
      'candidates': candidates,
      'baselines': 'protected_external',
      'catalog_generation': catalog['generation']
    };
  }

  Future<Map<String, dynamic>> execute(
          String operation, Map<String, dynamic> approved) =>
      transaction.run(operation, {'kind': 'cleanup', 'plan': approved},
          (catalog) async {
        require(approved['application_id'] == catalog['application_id'],
            'PUBLISH_RETENTION_STALE', 'Cleanup application differs');
        final current = plan(catalog, approved['cutoff'] as int);
        // Gate acquisition changes generation only. Re-evaluate all actual references.
        require(
            digest(encode({'rows': current['candidates']})) ==
                digest(encode({'rows': approved['candidates']})),
            'PUBLISH_RETENTION_STALE',
            'References changed; cleanup plan is stale');
        final deleted = <String>[];
        for (final candidate in (approved['candidates'] as List)) {
          final name = candidate['object'] as String;
          final object = await transaction.store.read(name);
          require(
              object == null ||
                  (digest(object.bytes) == candidate['sha256'] &&
                      object.bytes.length == candidate['size']),
              'PUBLISH_OBJECT_CHANGED',
              'Cleanup object identity changed');
          if (object != null) await transaction.store.delete(name);
          require(
              await transaction.store.read(name) == null,
              'PUBLISH_DELETE_UNKNOWN',
              'Deletion readback failed; resume cleanup');
          (catalog['releases'] as Map)[candidate['release']]['deleted'] = true;
          deleted.add(name);
        }
        return {
          'status': 'cleanup_complete',
          'operation': operation,
          'deleted': deleted
        };
      });
}
