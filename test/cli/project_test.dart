import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:flutter_patcher/src/cli/core.dart';

import 'dart:convert';

import 'package:flutter_patcher/src/cli/build/host_policy.dart';
import 'package:flutter_patcher/src/cli/crypto/ed25519.dart';
import 'package:flutter_patcher/src/cli/project.dart';

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

  test(
    'a project without a policy gets one from its build and patch key',
    () async {
      gradle('android { defaultConfig { applicationId = "com.example.app" } }');
      final config = await ProjectConfig.load(project.path);
      final policy = await HostPolicy.of(
        project.path,
        config,
        platform: 'android',
      );
      expect(policy.fields, {
        'schema': '2',
        'strategy': 'bytecode',
        'abi': 'arm64-v8a',
        'application_id': 'com.example.app',
        'version_code': '42',
        'flavor': 'default',
        'channel': 'production',
        'fptc_key': keys['patch'],
      });
      expect(policy.signed, isTrue);
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
    },
  );
  test('a project without a patch key builds unsigned hosts', () async {
    gradle('android { defaultConfig { applicationId = "com.example.app" } }');
    File(p.join(project.path, ProjectConfig.file)).deleteSync();
    final policy = await HostPolicy.of(
      project.path,
      await ProjectConfig.load(project.path),
      platform: 'android',
    );
    expect(policy.fields['fptc_key'], '-');
    expect(policy.signed, isFalse);
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
    expect(config.patchKey, isNull);
    expect(config.baselinesInProject, isTrue);
    for (final text in [
      'keys: other_keys\n',
      'store: [1]\n',
      'trust:\n  root: ${keys['root']}\n',
      'trust:\n  patch: not-a-key\n',
      'trust:\n  patch: ${keys['patch']}\n  other: x\n',
      'trust:\n  patch: ${keys['patch']}\n  enabled: maybe\n',
      'trust:\n  enabled: true\n',
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

  test('the patch key of a 1.0 project is read past its other keys', () async {
    final config = await ProjectConfig.load(project.path);
    expect(config.patchKey, keys['patch']);
    // A key without trust.enabled signs, as such hosts always did.
    expect([config.signingEnabled, config.hostKey], [true, keys['patch']]);
  });

  test('trust.enabled turns signing on and off', () async {
    final file = File(p.join(project.path, ProjectConfig.file));
    for (final (enabled, signed) in [('true', true), ('false', false)]) {
      file.writeAsStringSync(
        'trust:\n  patch: ${keys['patch']}\n  enabled: $enabled\n',
      );
      final config = await ProjectConfig.load(project.path);
      expect(config.patchKey, keys['patch']);
      expect(config.signingEnabled, signed);
      expect(config.hostKey, signed ? keys['patch'] : null);
    }
  });

  test('create writes the template only when there is no file', () async {
    final file = File(p.join(project.path, ProjectConfig.file))..deleteSync();
    final config = await ProjectConfig.load(project.path);
    expect(await config.create(), true);
    expect(file.readAsStringSync(), ProjectConfig.template);
    expect((await ProjectConfig.load(project.path)).patchKey, isNull);
    file.writeAsStringSync('store: file:///tmp/p\n');
    expect(await config.create(), false);
    expect(file.readAsStringSync(), 'store: file:///tmp/p\n');
  });

  test('a patch key is added to a file as written', () async {
    final file = File(p.join(project.path, ProjectConfig.file))
      ..writeAsStringSync('# mine\nstore: file:///tmp/p\n');
    await (await ProjectConfig.load(project.path)).writeTrust(keys['patch']!);
    final config = await ProjectConfig.load(project.path);
    expect(
      file.readAsStringSync(),
      startsWith('# mine\nstore: file:///tmp/p\n'),
    );
    expect(config['store'], 'file:///tmp/p');
    expect(config.patchKey, keys['patch']);
    expect(config.signingEnabled, false);
  });

  test('url defaults to serve and accepts only an http(s) address', () async {
    final yaml = File(p.join(project.path, ProjectConfig.file));
    final trust = yaml.readAsStringSync();
    var config = await ProjectConfig.load(project.path);
    expect([config.url, config.urlIsLocal], [ProjectConfig.localUrl, true]);
    yaml.writeAsStringSync('url: http://127.0.0.1:9000\n$trust');
    expect(
      (await ProjectConfig.load(project.path)).url,
      'http://127.0.0.1:9000',
    );
    yaml.writeAsStringSync('url: https://cdn.example.com/my-app/\n$trust');
    config = await ProjectConfig.load(project.path);
    expect(
      [config.url, config.urlIsLocal],
      ['https://cdn.example.com/my-app', false],
    );
    for (final bad in [
      's3://bucket/app',
      'https://cdn.example.com/a?x=1',
      'http://cdn.example.com/app',
    ]) {
      yaml.writeAsStringSync('url: $bad\n$trust');
      await expectLater(
        ProjectConfig.load(project.path),
        failure('CONFIG_INVALID'),
      );
    }
  });
}
