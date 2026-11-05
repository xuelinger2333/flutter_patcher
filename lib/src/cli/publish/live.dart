import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../../publication_scope.dart';
import '../core.dart';

/// The fields of the signed manifest devices download for [scope] from
/// [url], or null when nothing is published there yet: publish reads it
/// before numbering, as `git push` checks the remote first. Its numbers only
/// keep publish from going below what devices may hold; the signature is
/// not checked, since whoever can change the files can also delete them.
Future<Map<String, String>?> liveManifest(
  String url,
  Map<String, String> scope,
) async {
  final address = Uri.parse('$url/manifests/${scopeOf(scope)}.json');
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
  List<int> bytes;
  try {
    final response = await (await client.getUrl(address))
        .close()
        .timeout(const Duration(seconds: 30));
    if (response.statusCode == HttpStatus.notFound) {
      await response.drain<void>();
      return null;
    }
    if (response.statusCode != HttpStatus.ok) {
      await response.drain<void>();
      throw Failure(
        'PUBLISH_URL_UNREACHABLE',
        '$address answered ${response.statusCode}. publish reads what devices '
            'see at url before numbering a patch; a release with nothing '
            'published must answer 404.',
      );
    }
    bytes = await response
        .fold<List<int>>([], (all, chunk) => all..addAll(chunk))
        .timeout(const Duration(seconds: 30));
  } on Failure {
    rethrow;
  } catch (error) {
    throw Failure(
      'PUBLISH_URL_UNREACHABLE',
      'Cannot read $address: $error. publish reads what devices see at url '
          'before numbering a patch; check url in flutter_patcher.yaml and '
          'the network.',
    );
  } finally {
    client.close(force: true);
  }
  Map<String, String> fields;
  try {
    final envelope = jsonDecode(utf8.decode(bytes)) as Map;
    fields = Map<String, String>.from(
      jsonDecode(utf8.decode(base64Decode(envelope['payload'] as String)))
          as Map,
    );
    int.parse(fields['revision']!);
    int.parse(
      fields[fields['action'] == 'withdraw'
          ? 'withdraw_through_seq'
          : 'patch_seq']!,
    );
  } catch (_) {
    throw Failure(
      'PUBLISH_URL_INVALID',
      '$address is not a manifest flutter_patcher published.',
    );
  }
  require(
    scope.entries.every((e) => fields[e.key] == e.value),
    'PUBLISH_URL_INVALID',
    '$address holds the manifest of another release.',
  );
  return fields;
}

/// A release's revision, highest sequence and withdrawal floor: the
/// catalog's record [head], raised to what devices see in [live].
({int revision, int high, int floor}) releaseState(
  Map? head,
  Map<String, String>? live,
) {
  var revision = head?['revision'] as int? ?? 0,
      high = head?['high_seq'] as int? ?? 0,
      floor = head?['withdrawn_through'] as int? ?? 0;
  if (live != null) {
    revision = max(revision, int.parse(live['revision']!));
    if (live['action'] == 'withdraw') {
      final through = int.parse(live['withdraw_through_seq']!);
      high = max(high, through);
      floor = max(floor, through);
    } else {
      high = max(high, int.parse(live['patch_seq']!));
    }
  }
  return (revision: revision, high: high, floor: floor);
}
