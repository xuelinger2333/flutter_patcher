import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:test/test.dart';

import 'package:flutter_patcher/src/cli/build/host_policy.dart';
import 'package:flutter_patcher/src/cli/core.dart';
import 'package:flutter_patcher/src/cli/project.dart';

Matcher fails(String code) =>
    throwsA(isA<Failure>().having((f) => f.code, 'code', code));

/// Host policy schema 2.
void main() {
  final key = base64Encode(List.filled(32, 3));
  final fields = {
    'schema': '2',
    'strategy': 'bytecode',
    'abi': 'arm64-v8a',
    'application_id': 'com.example.app',
    'version_code': '7',
    'flavor': 'default',
    'channel': 'production',
    'fptc_key': key,
  };

  test('names the build and the patch key, canonically', () {
    final policy = HostPolicy(fields);
    expect(policy.signed, isTrue);
    expect(policy.patchKey, key);
    final sorted = (fields.keys.toList()..sort());
    expect(
      policy.canonical,
      jsonEncode({for (final k in sorted) k: fields[k]}),
    );
    expect(
      policy.digest,
      sha256.convert(utf8.encode(policy.canonical)).toString(),
    );
    expect(HostPolicy.parse(policy.canonical).digest, policy.digest);
    expect(
      () => HostPolicy.parse('${policy.canonical}\n'),
      throwsFormatException,
    );
  });

  test('`-` is a host that takes unsigned patch files', () {
    final policy = HostPolicy({...fields, 'fptc_key': '-'});
    expect(policy.signed, isFalse);
  });

  test('anything else is rejected', () {
    for (final change in <Map<String, String?>>[
      {'schema': '1'},
      {'schema': '3'},
      {'channel': null},
      {'extra': 'x'},
      {'fptc_key': 'AAAA'},
      {'fptc_key': ''},
      {'abi': 'x86_64'},
      {'strategy': 'jit'},
      {'abi': 'ios-arm64', 'strategy': 'so'},
      {'version_code': '07'},
      {'version_code': '2100000001'},
      {'flavor': 'a b'},
      {'flavor': 'a-b'},
      {'channel': 'b-c'},
      {'channel': 'c' * 65},
      {'application_id': 'example'},
    ]) {
      final values = {...fields};
      change.forEach((k, v) => v == null ? values.remove(k) : values[k] = v);
      expect(
        () => HostPolicy(values),
        throwsFormatException,
        reason: '$change',
      );
    }
    expect(
      HostPolicy({...fields, 'abi': 'ios-arm64'}).fields['abi'],
      'ios-arm64',
    );
  });

  test('a flavor or channel with anything but letters, digits and _ is a '
      'usage error', () async {
    final project = await Directory.systemTemp.createTemp('policy-of-');
    addTearDown(() => project.delete(recursive: true));
    final config = await ProjectConfig.load(project.path);
    for (final (flavor, channel) in [('paid-pro', null), (null, 'beta-1')]) {
      await expectLater(
        HostPolicy.of(
          project.path,
          config,
          platform: 'android',
          applicationId: 'com.example.app',
          versionCode: '1',
          flavor: flavor,
          channel: channel,
        ),
        throwsA(
          isA<Failure>().having((f) => f.code, 'code', 'BUILD_CONFIG_INVALID'),
        ),
      );
    }
    final policy = await HostPolicy.of(
      project.path,
      config,
      platform: 'android',
      applicationId: 'com.example.app',
      versionCode: '1',
      flavor: 'paid_pro',
      channel: 'beta1',
    );
    expect(policy.fields['flavor'], 'paid_pro');
  });

  test('a baseline of a flutter_patcher 1.0 host is not patched here', () {
    final legacy = {
      ...fields,
      'schema': '1',
      'root_key': key,
      'keys': 'release:$key',
    };
    final text = jsonEncode({
      for (final k in legacy.keys.toList()..sort()) k: legacy[k],
    });
    expect(() => HostPolicy.parse(text), fails('PATCH_BASELINE_INCOMPATIBLE'));
  });

  test('a 1.0 policy file keeps its patch key for a new build', () {
    final policy = HostPolicy.read(
      jsonEncode({
        ...fields,
        'schema': '1',
        'root_key': base64Encode(List.filled(32, 1)),
        'keys': 'release:$key',
      }),
    );
    expect(policy.fields, fields);
    expect(HostPolicy.read(jsonEncode(fields)).fields, fields);
    expect(
      () => HostPolicy.read(jsonEncode({...fields, 'strategy': 'jit'})),
      fails('BUILD_CONFIG_INVALID'),
    );
    expect(() => HostPolicy.read('[1]'), fails('BUILD_CONFIG_INVALID'));
  });
}
