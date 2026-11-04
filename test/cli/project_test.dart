import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:flutter_patcher/src/cli/core.dart';

import 'dart:convert';

import 'package:flutter_patcher/src/cli/build/host_policy.dart';
import 'package:flutter_patcher/src/cli/crypto/ed25519.dart';
import 'package:flutter_patcher/src/cli/project.dart';
import 'package:flutter_patcher/src/cli/publish/pipeline.dart';

Matcher failure(String code) =>
    throwsA(isA<Failure>().having((e) => e.code, 'code', code));

void main() {
  late Directory project;
  final keys = {
    for (final role in ['root', 'publisher', 'patch'])
      role: base64Encode(ed25519PublicKey(ed25519GenerateSeed())),
  };
  setUp(() async {
    project = await Directory.systemTemp.createTemp('project-');
    File(p.join(project.path, 'pubspec.yaml'))
        .writeAsStringSync('name: app\nversion: 2.1.0+42\n');
    for (final role in ['root', 'publisher', 'patch']) {
      File(
          p.join(
            project.path,
            'flutter_patcher_keys',
            role,
            'public-key.base64',
          ),
        )
        ..createSync(recursive: true)
        ..writeAsStringSync('${keys[role]}\n');
    }
  });
  tearDown(() => project.delete(recursive: true));
  void gradle(String text) =>
      File(p.join(project.path, 'android/app/build.gradle.kts'))
        ..createSync(recursive: true)
        ..writeAsStringSync(text);

  test('a project without a policy gets one from its build and keys', () async {
    gradle('android { defaultConfig { applicationId = "com.example.app" } }');
    final config = await ProjectConfig.load(project.path);
    final policy = await HostPolicy.of(
      project.path,
      config,
      platform: 'android',
    );
    expect(policy.fields, {
      'schema': '1',
      'strategy': 'bytecode',
      'abi': 'arm64-v8a',
      'application_id': 'com.example.app',
      'version_code': '42',
      'flavor': 'default',
      'channel': 'production',
      'root_key': keys['root'],
      'fptc_key': keys['patch'],
      'keys': 'release:${keys['publisher']}',
    });
    final custom = await HostPolicy.of(
      project.path,
      config,
      platform: 'android',
      strategy: 'so',
      channel: 'beta',
      versionCode: '7',
    );
    expect(
      [
        custom.fields['strategy'],
        custom.fields['channel'],
        custom.fields['version_code'],
      ],
      ['so', 'beta', '7'],
    );
  });
  test('the application id comes from exactly one declaration', () async {
    final config = await ProjectConfig.load(project.path);
    await expectLater(
      HostPolicy.of(project.path, config, platform: 'android'),
      failure('BUILD_CONFIG_INVALID'),
    );
    gradle(
      'applicationId = "a.b"\nproductFlavors { paid { applicationId = "a.c" } }',
    );
    await expectLater(
      HostPolicy.of(project.path, config, platform: 'android'),
      failure('BUILD_CONFIG_INVALID'),
    );
    File(p.join(project.path, 'ios/Runner.xcodeproj/project.pbxproj'))
      ..createSync(recursive: true)
      ..writeAsStringSync(
        'PRODUCT_BUNDLE_IDENTIFIER = com.example.app;\n'
        'PRODUCT_BUNDLE_IDENTIFIER = com.example.app.RunnerTests;\n'
        'PRODUCT_BUNDLE_IDENTIFIER = com.example.app;\n',
      );
    await expectLater(
      HostPolicy.of(project.path, config, platform: 'ios', strategy: 'so'),
      failure('BUILD_CONFIG_INVALID'),
    );
  });
  test('a pubspec version without a build number is refused', () async {
    File(p.join(project.path, 'pubspec.yaml'))
        .writeAsStringSync('name: app\nversion: 2.1.0\n');
    await expectLater(
      buildNumber(project.path),
      failure('BUILD_CONFIG_INVALID'),
    );
  });
  test('settings are strings with known names', () async {
    File(p.join(project.path, ProjectConfig.file))
        .writeAsStringSync('store: file:///tmp/p\nkeys: other_keys\n');
    final config = await ProjectConfig.load(project.path);
    expect(config['store'], 'file:///tmp/p');
    expect(config.keys, p.join(project.path, 'other_keys'));
    expect(config.baselinesInProject, isTrue);
    File(p.join(project.path, ProjectConfig.file))
        .writeAsStringSync('stores: x\n');
    await expectLater(
      ProjectConfig.load(project.path),
      failure('CONFIG_INVALID'),
    );
    File(p.join(project.path, ProjectConfig.file))
        .writeAsStringSync(ProjectConfig.template);
    expect((await ProjectConfig.load(project.path))['store'], isNull);
  });
  test(
    'the next sequence is above everything published for the fingerprint',
    () {
      final catalog = {
        'releases': {
          'a': {'fingerprint': 'f', 'high_seq': 3, 'withdrawn_through': 0},
          'b': {'fingerprint': 'f', 'high_seq': 2, 'withdrawn_through': 5},
          'c': {'fingerprint': 'g', 'high_seq': 9},
        },
      };
      expect(nextSequence(catalog, 'f'), 6);
      expect(nextSequence(catalog, 'h'), 1);
    },
  );
}
