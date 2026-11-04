import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:flutter_patcher/src/cli/core.dart';
import 'package:flutter_patcher/src/cli/sdk/artifacts.dart';
import 'package:flutter_patcher/src/cli/sdk/environment.dart';
import 'package:flutter_patcher/src/cli/sdk/host.dart';

const mac = HostIdentity('macos', 'arm64');
final sdk = SdkIdentity(
  '/selected/sdk',
  '3.47.2',
  'a' * 40,
  '3.13.2',
  'b' * 40,
  host: mac,
);
Matcher failure(String code) =>
    isA<Failure>().having((e) => e.code, 'code', code);
String digest(List<int> bytes) => sha256.convert(bytes).toString();

/// An iOS engine release: framework zip plus the macOS gen_snapshot.
class IosRelease {
  final binary = [207, 250, 237, 254, 12, 0, 0, 1, ...List.filled(24, 7)];
  final snapshot = [207, 250, 237, 254, 12, 0, 0, 1, ...List.filled(24, 9)];
  late List<int> zip;
  late Map<String, dynamic> manifest;

  IosRelease({
    String extra = 'Flutter.xcframework/ios-arm64/Flutter.framework/Info.plist',
  }) {
    zip = ZipEncoder().encode(
      Archive()
        ..addFile(ArchiveFile('Flutter.xcframework/Info.plist', 1, [1]))
        ..addFile(ArchiveFile(iosFrameworkBinary, binary.length, binary))
        ..addFile(ArchiveFile(extra, 1, [2])),
    );
    manifest = {
      'schema': 1,
      'flutter_version': sdk.version,
      'engine_commit': sdk.engine,
      'builder_repo_commit': 'c' * 40,
      'patches': [
        {'file': 'p.patch', 'sha256': 'd' * 64},
      ],
      'depot_tools_rev': 'e' * 40,
      'build_id': '930ce683-2072-4028-ba2c-e739451cf2a1',
      'engine_api': 1,
      'capabilities': ['asset_overlay', 'isolate_entry'],
      'built_at': '2026-10-30T08:00:00Z',
      'verify': {
        'snapshot': 'passed',
        'device': 'skipped',
        'device_reason': 'no_ios_device',
      },
      'files': [
        {
          'role': 'framework',
          'name': iosFrameworkZip,
          'size': zip.length,
          'sha256': digest(zip),
          'contents': [
            {
              'name': iosFrameworkBinary,
              'size': binary.length,
              'sha256': digest(binary),
            },
          ],
        },
        {
          'role': 'gen_snapshot',
          'name': iosGenSnapshot,
          'host_os': 'macos',
          'host_arch': 'arm64',
          'size': snapshot.length,
          'sha256': digest(snapshot),
        },
      ],
    };
  }

  Future<void> write(String directory) async {
    await File(p.join(directory, iosFrameworkZip)).writeAsBytes(zip);
    await File(p.join(directory, iosGenSnapshot)).writeAsBytes(snapshot);
  }
}

class NoCommands extends Commands {
  NoCommands(super.cache);
  @override
  Future<String> run(
    String executable,
    List<String> args, {
    String? cwd,
    List<int>? inputBytes,
    String code = 'TOOL_FAILED',
    Duration timeout = const Duration(minutes: 15),
    Map<String, String>? extraEnvironment,
  }) async => '';
}

void main() {
  late Directory temp;
  setUp(
    () async => temp = await Directory.systemTemp.createTemp('ios-engine-'),
  );
  tearDown(() => temp.delete(recursive: true));

  test('iOS engine manifest: shared provenance, iOS skip reason', () async {
    final release = IosRelease();
    checkManifest(release.manifest, 'engine-ios', sdk);
    final android =
        jsonDecode(jsonEncode(release.manifest)) as Map<String, dynamic>;
    android['verify']['device_reason'] = 'no_android_device';
    expect(
      () => checkManifest(android, 'engine-ios', sdk),
      throwsA(failure('ENGINE_MANIFEST_INVALID')),
    );
    await release.write(temp.path);
    await validateFiles(temp.path, release.manifest, host: mac);
  });

  test('a framework zip cannot escape Flutter.xcframework', () async {
    final release = IosRelease(extra: 'Flutter.xcframework/../evil');
    await release.write(temp.path);
    await expectLater(
      validateFiles(temp.path, release.manifest, host: mac),
      throwsA(failure('ARTIFACT_INVALID')),
    );
  });

  test('the managed SDK gets the patched framework and gen_snapshot', () async {
    final release = IosRelease();
    final store = ArtifactStore(
      temp.path,
      Uri.parse('http://127.0.0.1/'),
      Uri.parse('http://127.0.0.1/'),
      Downloads(offline: true),
    )..select([ArtifactRelease('engine-ios-3.47.2-930ce683', 'a' * 64)]);
    final cached = p.dirname(store.file(sdk, 'engine-ios', iosFrameworkZip));
    await Directory(cached).create(recursive: true);
    await release.write(cached);
    final target = p.join(temp.path, 'sdk');
    final ios = p.join(target, 'bin/cache/artifacts/engine/ios-release');
    await File(p.join(ios, 'Flutter.xcframework/stock-only'))
        .create(recursive: true);
    final builder = EnvironmentBuilder(temp.path, NoCommands(temp.path));
    await builder.installIos(sdk, store, release.manifest, target);
    expect(
      await File(p.join(ios, iosFrameworkBinary)).readAsBytes(),
      release.binary,
    );
    expect(
      await File(p.join(ios, 'gen_snapshot_arm64')).readAsBytes(),
      release.snapshot,
    );
    expect(
      File(p.join(ios, 'Flutter.xcframework/stock-only')).existsSync(),
      isFalse,
    );
    // A tampered device binary is replaced on the next run.
    await File(p.join(ios, iosFrameworkBinary)).writeAsBytes([0]);
    await builder.installIos(sdk, store, release.manifest, target);
    expect(
      await File(p.join(ios, iosFrameworkBinary)).readAsBytes(),
      release.binary,
    );
  });
}
