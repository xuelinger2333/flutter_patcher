import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:flutter_patcher_cli/src/core.dart';
import 'package:flutter_patcher_cli/src/baseline/archive.dart';
import 'package:flutter_patcher_cli/src/baseline/manifest.dart';
import 'package:flutter_patcher_cli/src/baseline/repository.dart';
import 'package:flutter_patcher_cli/src/baseline/store.dart';

Map<String, dynamic> metadata() => {
      'schema': 1,
      'flutter_version': '3.47.2',
      'engine_commit': 'a' * 40,
      'build_id': '11111111-1111-4111-8111-111111111111',
      'platform': {
        'path':
            'bin/cache/artifacts/engine/common/flutter_patched_sdk_product/platform_strong.dill',
        'sha256': 'b' * 64
      }
    };

Future<void> fixture(String root) async {
  await Directory(root).create(recursive: true);
  await File(p.join(root, 'app.dill'))
      .writeAsString('unit-test kernel bytes, not a built application');
  await File(p.join(root, 'libapp.so')).writeAsString('unit-test ELF stand-in');
  await File(p.join(root, 'dynamic_interface.yaml')).writeAsString(
      '{"callable":[{"library":"package:app/main.dart","class":"Widget"}]}\n');
  await writeObject(p.join(root, 'interface_detailed.json'), {
    'schema': 1,
    'interface_sha256': await hashFile(p.join(root, 'dynamic_interface.yaml')),
    'entries': [
      {
        'section': 'callable',
        'library': 'package:app/main.dart',
        'class': 'Widget',
        'sources': ['referenced'],
        'location': null
      }
    ]
  });
  await writeObject(p.join(root, 'package_config.json'),
      {'configVersion': 2, 'packages': []});
  await writeObject(p.join(root, 'source_hashes.json'), {
    'schema': 1,
    'files': {'package:app/main.dart': 'c' * 64}
  });
  await writeObject(p.join(root, 'allocate_finalized.json'), {
    'schema': 1,
    'classes': ['package:app/main.dart::Widget']
  });
  await writeObject(p.join(root, 'baseline.manifest.json'),
      await createManifest(root, metadata()));
}

class CountingStore implements BaselineStore {
  final BaselineStore inner;
  int reads = 0;
  bool failPut = false;
  CountingStore(this.inner);
  @override
  Future<void> probe() => inner.probe();
  @override
  Future<bool> get(String n, String d) {
    reads++;
    return inner.get(n, d);
  }

  @override
  Future<bool> put(String n, String s) {
    if (failPut) {
      throw Failure('BASELINE_STORE_UNREACHABLE', 'Injected upload failure');
    }
    return inner.put(n, s);
  }
}

void main() {
  late Directory temp;
  late String input, storePath;
  late CountingStore store;
  late BaselineRepository repository;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('wp4-test-');
    input = p.join(temp.path, 'input');
    await fixture(input);
    storePath = p.join(temp.path, 'store');
    await Directory(storePath).create();
    store = CountingStore(FileBaselineStore(storePath));
    repository = BaselineRepository(p.join(temp.path, 'cache-a'), store);
  });
  // Preserve these small test fixtures for diagnosis; no existing files removed.
  test('fingerprint fixed vector and every input participates', () {
    final value = fingerprint('1' * 64, '2' * 40, '3' * 64, '3.47.2');
    expect(value,
        '119e99508c34e22de366c4d6cc838d47cccf16962c06c3f23a43a421d10953e2');
    expect(
        {
          value,
          fingerprint('4' * 64, '2' * 40, '3' * 64, '3.47.2'),
          fingerprint('1' * 64, '4' * 40, '3' * 64, '3.47.2'),
          fingerprint('1' * 64, '2' * 40, '4' * 64, '3.47.2'),
          fingerprint('1' * 64, '2' * 40, '3' * 64, '3.47.3')
        }.length,
        5);
    expect(() => fingerprint('bad', '2' * 40, '3' * 64, '3.47.2'),
        throwsA(isA<Failure>()));
  });
  test('schema 4 binds the framework partition without changing legacy inputs',
      () async {
    final root = p.join(temp.path, 'schema4');
    await fixture(root);
    final partition = p.join(root, 'framework_partition.json');
    await writeObject(partition, {
      'schema': 1,
      'host': ['package:flutter/src/widgets/framework.dart'],
      'carry': ['package:flutter/src/material/expansion_tile.dart'],
      'libraries': [],
    });
    await writeObject(p.join(root, 'compiler_interface.json'), {
      'callable': [
        {'library': 'package:app/main.dart', 'class': 'Widget'}
      ]
    });
    final m = metadata()
      ..['schema'] = 4
      ..['runtime_bootstrap'] = true
      ..['framework_partition_sha256'] = await hashFile(partition);
    final receipt = {
      'runtime_bootstrap': true,
      'fingerprint': fingerprint(
          await hashFile(p.join(root, 'app.dill')),
          m['engine_commit'] as String,
          await hashFile(p.join(root, 'dynamic_interface.yaml')),
          m['flutter_version'] as String,
          frameworkPartitionHash: m['framework_partition_sha256'] as String),
      'app_only': true,
      'interface_sha256':
          await hashFile(p.join(root, 'dynamic_interface.yaml')),
      'libapp_sha256': await hashFile(p.join(root, 'libapp.so')),
      'apk_sha256': 'd' * 64,
    };
    await writeObject(p.join(root, 'build_receipt.json'), receipt);
    final result = await createManifest(root, m);
    expect(result['schema'], 4);
    expect(result['fingerprint'], receipt['fingerprint']);
    await File(partition)
        .writeAsString('{"schema":1,"host":[],"carry":[],"libraries":[]}');
    await expectLater(createManifest(root, m), throwsA(isA<Failure>()));
  });
  test('manifest is path independent and detects payload tampering', () async {
    final other = p.join(temp.path, 'other');
    await fixture(other);
    expect(canonical(await verifyBaseline(input)),
        canonical(await verifyBaseline(other)));
    await File(p.join(other, 'libapp.so')).writeAsString('changed');
    await expectLater(verifyBaseline(other), throwsA(isA<Failure>()));
  });
  test('detail content mismatch is rejected even with correct interface hash',
      () async {
    final path = p.join(input, 'interface_detailed.json');
    final detail = await baselineObject(path);
    detail['entries'] = [];
    await writeObject(path, detail);
    await expectLater(
        createManifest(input, metadata()), throwsA(isA<Failure>()));
  });
  test('SDK location is relative and hash is verified at new location',
      () async {
    final sdk = p.join(temp.path, 'different-sdk');
    final m = metadata();
    final platform = p.join(sdk, (m['platform'] as Map)['path'] as String);
    await File(platform).parent.create(recursive: true);
    await File(platform).writeAsString('platform');
    await File(p.join(sdk, 'bin/internal/engine.version'))
        .parent
        .create(recursive: true);
    await File(p.join(sdk, 'bin/internal/engine.version'))
        .writeAsString('a' * 40);
    (m['platform'] as Map)['sha256'] = await hashFile(platform);
    await writeObject(p.join(input, 'baseline.manifest.json'),
        await createManifest(input, m));
    await verifyBaseline(input, sdkRoot: sdk);
    await File(platform).writeAsString('wrong');
    await expectLater(
        verifyBaseline(input, sdkRoot: sdk), throwsA(isA<Failure>()));
  });
  test('absolute source identities and missing allocation records fail',
      () async {
    await writeObject(p.join(input, 'source_hashes.json'), {
      'schema': 1,
      'files': {'file:///tmp/a.dart': 'c' * 64}
    });
    await expectLater(
        createManifest(input, metadata()), throwsA(isA<Failure>()));
  });
  test('file store conditional create is immutable under concurrent callers',
      () async {
    final name = 'baseline-${'d' * 64}.tar.zst';
    final values = await Future.wait(
        List.generate(3, (_) => store.put(name, p.join(input, 'app.dill'))));
    expect(values.where((v) => v).length, 1);
    expect(await hashFile(p.join(storePath, name)),
        await hashFile(p.join(input, 'app.dill')));
  });
  group('real zstd archives', () {
    test('wrong selected SDK does not quarantine an intact cache', () async {
      final saved = await repository.save(input, metadata(),
          flavor: 'prod', versionCode: '42');
      final id = saved['fingerprint'] as String;
      await expectLater(
          repository.fetch(id, sdkRoot: p.join(temp.path, 'wrong-sdk')),
          throwsA(isA<Failure>()));
      expect(await Directory(p.join(repository.cache, id)).exists(), true);
      await verifyBaseline(p.join(repository.cache, id));
    });
    test('CLI save/fetch/verify and archive failure have meaningful exit codes',
        () async {
      final package = Directory.current.path;
      final firstCache = p.join(package,
          '.dart_tool/flutter_patcher/wp4-cli-${DateTime.now().microsecondsSinceEpoch}');
      final secondCache = '$firstCache-second';
      final descriptor = p.join(temp.path, 'metadata.json');
      await writeObject(descriptor, metadata());
      Future<ProcessResult> cli(List<String> args) => Process.run(
          Platform.resolvedExecutable,
          [p.join(package, 'bin/flutter_patcher.dart'), 'baseline', ...args],
          workingDirectory: package);
      final saved = await cli([
        '--action',
        'save',
        '--baseline',
        input,
        '--metadata',
        descriptor,
        '--baseline-store',
        Uri.directory(storePath).toString(),
        '--version-code',
        '8',
        '--cache-dir',
        firstCache
      ]);
      expect(saved.exitCode, 0, reason: '${saved.stderr}');
      final id =
          (jsonDecode(saved.stdout as String) as Map)['fingerprint'] as String;
      final wrongSdk = await cli([
        '--action',
        'save',
        '--baseline',
        input,
        '--metadata',
        descriptor,
        '--version-code',
        '99',
        '--baseline-store',
        Uri.directory(storePath).toString(),
        '--cache-dir',
        firstCache,
        '--flutter-sdk',
        p.join(temp.path, 'wrong-sdk')
      ]);
      expect(wrongSdk.exitCode, isNot(0));
      expect(
          await File(p.join(storePath, 'release-default-99-arm64-v8a.json'))
              .exists(),
          false);
      final fetched = await cli([
        '--action',
        'fetch',
        '--fingerprint',
        id,
        '--baseline-store',
        Uri.directory(storePath).toString(),
        '--cache-dir',
        secondCache
      ]);
      expect(fetched.exitCode, 0, reason: '${fetched.stderr}');
      final offline = await cli([
        '--action',
        'fetch',
        '--fingerprint',
        id,
        '--offline',
        '--cache-dir',
        secondCache
      ]);
      expect(offline.exitCode, 0, reason: '${offline.stderr}');
      final failed = await cli([
        '--action',
        'save',
        '--baseline',
        input,
        '--metadata',
        descriptor,
        '--version-code',
        '9',
        '--baseline-store',
        Uri.directory(p.join(temp.path, 'missing-store')).toString(),
        '--cache-dir',
        firstCache
      ]);
      expect(failed.exitCode, isNot(0));
      expect((jsonDecode(failed.stderr as String) as Map)['status'], 'failed');
    });
    test('save, independent cache fetch, offline hit and sidecar binding',
        () async {
      final saved = await repository.save(input, metadata(),
          flavor: 'prod', versionCode: '42');
      final id = saved['fingerprint'] as String;
      final other = BaselineRepository(p.join(temp.path, 'cache-b'), store);
      final root = await other.fetch(id);
      expect(canonical(await verifyBaseline(root)),
          canonical(await verifyBaseline(input)));
      final before = store.reads;
      expect(await other.fetch(id), root);
      expect(store.reads, before);
      expect(
          await BaselineRepository(p.join(temp.path, 'cache-b'), null)
              .fetch(id),
          root);
      expect((await other.verifyRelease('prod', '42'))['fingerprint'], id);
      await repository.save(input, metadata(),
          flavor: 'prod', versionCode: '42');
    });
    test('same fingerprint with a different libapp never overwrites', () async {
      final saved = await repository.save(input, metadata(),
          flavor: 'prod', versionCode: '42');
      final object =
          p.join(storePath, 'baseline-${saved['fingerprint']}.tar.zst');
      final hash = await hashFile(object);
      await File(p.join(input, 'libapp.so')).writeAsString('different binary');
      await expectLater(
          repository.save(input, metadata(), flavor: 'prod', versionCode: '43'),
          throwsA(isA<Failure>()
              .having((e) => e.code, 'code', 'BASELINE_CONTENT_CONFLICT')));
      expect(await hashFile(object), hash);
      expect(
          await File(p.join(storePath, 'release-prod-43-arm64-v8a.json'))
              .exists(),
          false);
    });
    test('upload failure leaves no successful sidecar or promoted cache',
        () async {
      store.failPut = true;
      await expectLater(
          repository.save(input, metadata(), flavor: 'prod', versionCode: '42'),
          throwsA(isA<Failure>()));
      expect(
          await File(p.join(storePath, 'release-prod-42-arm64-v8a.json'))
              .exists(),
          false);
      final id = (await verifyBaseline(input))['fingerprint'] as String;
      expect(await Directory(p.join(repository.cache, id)).exists(), false);
    });
    test('damaged cache is quarantined and restored from archive', () async {
      final saved = await repository.save(input, metadata(),
          flavor: 'prod', versionCode: '42');
      final id = saved['fingerprint'] as String;
      await File(p.join(repository.cache, id, 'app.dill'))
          .writeAsString('broken');
      await verifyBaseline(await repository.fetch(id));
      expect(
          (await Directory(repository.cache).list().toList())
              .any((e) => e.path.contains('.invalid-')),
          true);
    });
    test('changed sidecar cannot bind a valid archive to another build',
        () async {
      await repository.save(input, metadata(),
          flavor: 'prod', versionCode: '42');
      final path = p.join(storePath, 'release-prod-42-arm64-v8a.json');
      final link = await baselineObject(path);
      link['libapp_sha256'] = 'f' * 64;
      await writeObject(path, link);
      await expectLater(
          repository.verifyRelease('prod', '42'), throwsA(isA<Failure>()));
    });
    test('unsafe tar name and links rejected before extraction', () async {
      final codec = BaselineArchive();
      final packed = p.join(temp.path, 'valid.zst');
      await codec.pack(input, packed);
      for (final type in ['path', 'link', 'duplicate']) {
        final bytes = await File('$packed.tar').readAsBytes();
        if (type == 'path') {
          bytes.fillRange(0, 100, 0);
          bytes.setRange(0, 8, ascii.encode('../owned'));
        }
        if (type == 'link') bytes[156] = 50;
        if (type == 'duplicate') {
          // Name the first entry after the second entry.
          final size =
              int.parse(ascii.decode(bytes.sublist(124, 135)), radix: 8);
          final next = 512 + ((size + 511) ~/ 512) * 512;
          bytes.setRange(0, 100, bytes.sublist(next, next + 100));
        }
        bytes.fillRange(148, 156, 32);
        final sum = bytes.take(512).fold<int>(0, (a, b) => a + b);
        bytes.setRange(148, 156,
            ascii.encode('${sum.toRadixString(8).padLeft(6, '0')}\u0000 '));
        final raw = p.join(temp.path, '$type.tar'),
            bad = p.join(temp.path, '$type.zst');
        await File(raw).writeAsBytes(bytes);
        await codec.codec(raw, bad);
        await expectLater(codec.unpack(bad, p.join(temp.path, 'out-$type')),
            throwsA(isA<Failure>()));
      }
      expect(await File(p.join(temp.path, 'owned')).exists(), false);
    });
    test('truncation and decompression size limits reject archives', () async {
      final packed = p.join(temp.path, 'valid.zst');
      await BaselineArchive().pack(input, packed);
      await expectLater(
          BaselineArchive(maxBytes: 100)
              .unpack(packed, p.join(temp.path, 'limited')),
          throwsA(isA<Failure>()));
      final bytes = await File(packed).readAsBytes();
      final truncated = p.join(temp.path, 'truncated');
      await File(truncated)
          .writeAsBytes(bytes.take(bytes.length ~/ 2).toList());
      await expectLater(
          BaselineArchive().unpack(truncated, p.join(temp.path, 'broken')),
          throwsA(isA<Failure>()));
    });
  }, skip: !Platform.isLinux ? 'Requires real Linux zstd' : false);
}
