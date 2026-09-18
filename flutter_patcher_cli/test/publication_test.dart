import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:flutter_patcher_cli/src/core.dart';
import 'package:flutter_patcher_cli/src/crypto/signing.dart';
import 'package:flutter_patcher_cli/src/publish/store.dart';
import 'package:flutter_patcher_cli/src/publish/transaction.dart';
import 'package:flutter_patcher_cli/src/publish/retention.dart';
import 'package:flutter_patcher_cli/src/publish/pipeline.dart';
import 'package:flutter_patcher_cli/src/publish/protocol.dart';

class DisruptedStore implements PublishStore {
  DisruptedStore(this.inner);
  final PublishStore inner;
  int lostReplies = 0;
  int failDelete = 0;
  @override
  Future<StoredObject?> read(String n) => inner.read(n);
  @override
  Future<List<String>> list() => inner.list();
  @override
  Future<bool> write(String n, List<int> b, String? token) async {
    final ok = await inner.write(n, b, token);
    if (lostReplies > 0) {
      lostReplies--;
      throw const SocketException('reply lost');
    }
    return ok;
  }

  @override
  Future<void> delete(String n) async {
    await inner.delete(n);
    if (failDelete > 0) {
      failDelete--;
      throw const SocketException('deleted but reply lost');
    }
  }
}

void main() {
  late Directory temp;
  late FilePublishStore store;
  late PublicationTransaction tx;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('publication-');
    store = FilePublishStore(p.join(temp.path, 'store'));
    tx = PublicationTransaction(store, 'com.example.app');
  });
  tearDown(() async => temp.delete(recursive: true));
  test('two clients cannot replace the same generation', () async {
    expect(await store.write('catalog.json', [1], null), true);
    final token = (await store.read('catalog.json'))!.token;
    final results = await Future.wait([
      store.write('catalog.json', [2], token),
      FilePublishStore(store.root).write('catalog.json', [3], token)
    ]);
    expect(results.where((x) => x).length, 1);
  });
  test('lost successful replies reconcile, same operation is idempotent',
      () async {
    final disrupted = DisruptedStore(store)..lostReplies = 2;
    final t = PublicationTransaction(disrupted, 'com.example.app');
    var calls = 0;
    Future<Map<String, dynamic>> action(Map<String, dynamic> _) async {
      calls++;
      return {'ok': true};
    }

    expect(await t.run('a' * 32, {'x': 1}, action), {'ok': true});
    expect(await t.run('a' * 32, {'x': 1}, action), {'ok': true});
    expect(calls, 1);
    await expectLater(
        t.run('a' * 32, {'x': 2}, action), throwsA(isA<Failure>()));
  });
  test('pending operation blocks another publisher and resumes after failure',
      () async {
    final entered = Completer<void>(), release = Completer<void>();
    final first = tx.run('a' * 32, {'x': 1}, (_) async {
      entered.complete();
      await release.future;
      return {'ok': true};
    });
    await entered.future;
    await expectLater(
        tx.run('b' * 32, {'x': 2}, (_) async => {}), throwsA(isA<Failure>()));
    release.complete();
    await first;
    await expectLater(
        tx.run('c' * 32, {'x': 3},
            (_) async => throw const SocketException('down')),
        throwsA(isA<SocketException>()));
    expect(await tx.run('c' * 32, {'x': 3}, (_) async => {'resumed': true}),
        {'resumed': true});
  });
  test('application namespace mismatch is rejected', () async {
    await tx.run('a' * 32, {}, (_) async => {});
    await expectLater(PublicationTransaction(store, 'other.app').snapshot(),
        throwsA(isA<Failure>()));
  });
  test('cleanup protects current and pin; interrupted delete is recoverable',
      () async {
    final names = [
      for (final op in ['a', 'b', 'c']) 'objects/${op * 32}/${digest([1])}.fptc'
    ];
    for (final name in names) {
      await store.write(name, [1], null);
    }
    await tx.run('d' * 32, {}, (catalog) async {
      catalog['releases'] = {
        for (var i = 0; i < 3; i++)
          '$i': {
            'object': names[i],
            'sha256': digest([1]),
            'size': 1,
            'created_at': 1,
            'pin': i == 1
          }
      };
      catalog['heads'] = {'scope': '2'};
      return {};
    });
    final disrupted = DisruptedStore(store)..failDelete = 1;
    final cleaner = PublicationRetention(
        PublicationTransaction(disrupted, 'com.example.app'));
    final plan = cleaner.plan(await tx.snapshot(), 10);
    expect((plan['candidates'] as List).length, 1);
    await expectLater(
        cleaner.execute('e' * 32, plan), throwsA(isA<SocketException>()));
    final result = await cleaner.execute('e' * 32, plan);
    expect(result['status'], 'cleanup_complete');
    expect(await store.read(names[0]), isNull);
    expect(await store.read(names[1]), isNotNull);
    expect(await store.read(names[2]), isNotNull);
    expect(await cleaner.execute('e' * 32, plan), result);
  });
  test('native vectors enforce publication sequence rules', () {
    final rows =
        jsonDecode(File('../test/protocol/manifest-v1.json').readAsStringSync())
            as List;
    for (final row in rows) {
      if (row['parse_valid'] != true) continue;
      final f =
          PublishManifest.parse(base64Decode(row['payload'] as String)).fields;
      final s = row['state'] as Map;
      final prior = {
        'revision': s['revision'] ?? 0,
        'high_seq': s['highSeq'] ?? 0,
        'patch_hash': s['patchHash'] ?? '',
        'withdrawn_through': s['withdrawnThrough'] ?? 0
      };
      if (int.parse(f['revision']!) <= (prior['revision'] as int)) {
        continue; // idempotence belongs to operation journal.
      }
      if (['sequence-conflict', 'republish-withdrawn'].contains(row['name'])) {
        expect(() => publicationPolicy(f, prior, prior['revision'] as int),
            throwsA(isA<Failure>()));
      } else if (row['verify_valid'] == true) {
        publicationPolicy(f, prior, prior['revision'] as int);
      }
    }
  });
  test('stale cleanup plan cannot delete a newly pinned release or strand gate',
      () async {
    final name = 'objects/${'a' * 32}/${digest([7])}.fptc';
    await store.write(name, [7], null);
    await tx.run('a' * 32, {}, (catalog) async {
      catalog['releases'] = {
        'old': {
          'object': name,
          'sha256': digest([7]),
          'size': 1,
          'created_at': 1,
          'pin': false
        }
      };
      return {};
    });
    final cleaner = PublicationRetention(tx);
    final oldPlan = cleaner.plan(await tx.snapshot(), 2);
    await tx.run('b' * 32, {}, (catalog) async {
      (catalog['releases'] as Map)['old']['pin'] = true;
      return {};
    });
    await expectLater(
        cleaner.execute('c' * 32, oldPlan), throwsA(isA<Failure>()));
    expect((await tx.snapshot())['pending'], isNull);
    expect(await store.read(name), isNotNull);
    expect(await tx.run('d' * 32, {}, (_) async => {'ok': true}), {'ok': true});
  });
  test('real OpenSSL publish, preview, withdraw and new sequence', () async {
    final commands = Commands(temp.path);
    const seed = 'nWGxne/9WmC6hEr0kuwsxERJxWl7MmkZcDusAxyuf2A=';
    const public = '11qYAYKxCrfVS/7TyWQHOg7hcvPapiMlrwIaaPcHURo=';
    final base = <String, String>{
      'schema': '1',
      'key_id': 'release',
      'application_id': 'com.example.app',
      'channel': 'stable',
      'flavor': 'default',
      'version_code': '1',
      'abi': 'arm64-v8a',
      'fingerprint': 'ab' * 32,
      'strategy': 'bytecode',
      'minPluginVersion': '2.0.0'
    };
    final identity = <String, dynamic>{
      'fingerprint': 'ab' * 32,
      'receipt': {
        'application_id': 'com.example.app',
        'version_code': '1',
        'public_key': public
      }
    };
    final pipe = PublicationPipeline(tx, commands, temp.path);
    final vector = (jsonDecode(
                File('../test/protocol/manifest-v1.json').readAsStringSync())
            as List)
        .first as Map;
    final manifestMessage = hexBytes(vector['signing_hex'] as String);
    expect(
        await signMessage(manifestMessage, seed, public,
            p.join(temp.path, 'vector-sign'), commands),
        hexBytes(vector['signature'] as String));
    final header = ByteData(82)
      ..setUint32(0, 0x46505443)
      ..setUint16(4, 1)
      ..setUint32(38, 1)
      ..setUint64(42, 1);
    final h = header.buffer.asUint8List();
    h.setRange(6, 38, List.filled(32, 0xab));
    h.setRange(50, 82, hexBytes(digest([7])));
    final sig = await signMessage(
        [...h, 7], seed, public, p.join(temp.path, 'sign-patch'), commands);
    final patch = Uint8List.fromList([...h, ...sig, 7]);
    final fields = {
      ...base,
      'revision': '1',
      'action': 'publish',
      'patch_seq': '1',
      'sha256': digest(patch),
      'size': '${patch.length}',
      'url': 'https://example.com/objects/${'a' * 32}/${digest(patch)}.fptc'
    };
    Future<Map<String, dynamic>> publish(bool commit) => pipe.execute(
        operation: 'a' * 32,
        fields: fields,
        expectedRevision: 0,
        seed: seed,
        publicKey: public,
        createdAt: '1',
        baseline: identity,
        patch: patch,
        commit: commit);
    expect((await publish(false))['status'], 'preview');
    expect(await store.read('catalog.json'), isNull);
    final receipt = await publish(true);
    expect(receipt['status'], 'published');
    expect(await publish(true), receipt);
    await expectLater(
        pipe.execute(
            operation: 'a' * 32,
            fields: fields,
            expectedRevision: 0,
            seed: seed,
            publicKey: public,
            createdAt: '1',
            baseline: identity,
            patch: patch,
            commit: false,
            pin: true),
        throwsA(isA<Failure>()));
    final withdraw = {
      ...base,
      'action': 'withdraw',
      'revision': '2',
      'withdraw_through_seq': '1'
    };
    expect(
        (await pipe.execute(
            operation: 'b' * 32,
            fields: withdraw,
            expectedRevision: 1,
            seed: seed,
            publicKey: public,
            createdAt: '2',
            baseline: identity,
            commit: true))['action'],
        'withdraw');
    await expectLater(
        pipe.execute(
            operation: 'c' * 32,
            fields: {
              ...fields,
              'revision': '3',
              'url': fields['url']!.replaceAll('a' * 32, 'c' * 32)
            },
            expectedRevision: 2,
            seed: seed,
            publicKey: public,
            createdAt: '3',
            baseline: identity,
            patch: patch,
            commit: true),
        throwsA(isA<Failure>()));
    final damaged = Uint8List.fromList(patch)..[82] ^= 1;
    await expectLater(
        verifyPublicationPatch(
            damaged, fields, public, p.join(temp.path, 'bad'), commands),
        throwsA(isA<Failure>()));
  },
      tags: 'openssl',
      skip: Platform.isLinux
          ? false
          : 'OpenSSL via /dev/stdin is POSIX-only until WP-2.6 phase B');
}
