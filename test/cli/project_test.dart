import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:flutter_patcher/src/cli/core.dart';

import 'dart:convert';

import 'package:flutter_patcher/src/cli/build/host_policy.dart';
import 'package:flutter_patcher/src/cli/crypto/ed25519.dart';
import 'package:flutter_patcher/src/cli/project.dart';
import 'package:flutter_patcher/src/cli/keys/bundle.dart';
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
    File(p.join(project.path, ProjectConfig.file)).writeAsStringSync(
      'trust:\n${[for (final e in keys.entries) '  ${e.key}: ${e.value}'].join('\n')}\n',
    );
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
  test('settings have known names and shapes', () async {
    void write(String text) =>
        File(p.join(project.path, ProjectConfig.file)).writeAsStringSync(text);
    write('store: file:///tmp/p\nsigning:\n  command: sign-it\n');
    final config = await ProjectConfig.load(project.path);
    expect(config['store'], 'file:///tmp/p');
    expect(config.signingCommand, 'sign-it');
    expect(config.anchors, isNull);
    expect(config.baselinesInProject, isTrue);
    expect(() => config.requireAnchors(), failure('KEYS_NOT_CONFIGURED'));
    for (final text in [
      'keys: other_keys\n',
      'store: [1]\n',
      'trust:\n  root: ${keys['root']}\n',
      'signing:\n  cmd: x\n',
    ]) {
      write(text);
      await expectLater(
        ProjectConfig.load(project.path),
        failure('CONFIG_INVALID'),
        reason: text,
      );
    }
    write(ProjectConfig.template);
    expect((await ProjectConfig.load(project.path))['store'], isNull);
  });

  test(
    'trust keys are added to a file as written, then only rotated',
    () async {
      final file = File(p.join(project.path, ProjectConfig.file))
        ..writeAsStringSync('# mine\nstore: file:///tmp/p\n');
      final anchors = TrustAnchors(
        root: keys['root']!,
        publisher: keys['publisher']!,
        patch: keys['patch']!,
      );
      await (await ProjectConfig.load(project.path)).writeTrust(anchors);
      final config = await ProjectConfig.load(project.path);
      expect(
        file.readAsStringSync(),
        startsWith('# mine\nstore: file:///tmp/p\n'),
      );
      expect(config['store'], 'file:///tmp/p');
      expect(config.anchors!.patch, keys['patch']);
      await expectLater(
        config.writeTrust(anchors),
        failure('KEYS_ALREADY_CONFIGURED'),
      );
      final rotated = base64Encode(ed25519PublicKey(ed25519GenerateSeed()));
      await config.writePublisher(rotated);
      final after = await ProjectConfig.load(project.path);
      expect(after.anchors!.publisher, rotated);
      expect(after.anchors!.root, keys['root']);
    },
  );
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
