import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'host_tools.dart';

import 'package:flutter_patcher/src/cli/core.dart';
import 'package:flutter_patcher/src/cli/sdk/host.dart';

void main() {
  Future<ProcessResult> cli(List<String> args) =>
      Process.run(dartVm, ['bin/flutter_patcher.dart', ...args]);

  test('help and version are usable without Flutter or a network', () async {
    final help = await cli(['--help']);
    expect(help.exitCode, 0);
    expect(help.stdout, contains('flutter_patcher doctor'));
    final version = await cli(['--version']);
    expect(version.exitCode, 0);
    expect(version.stdout, startsWith('flutter_patcher '));
  });
  test('keys requires an explicit initialization subcommand', () async {
    for (final command in ['keys']) {
      final result = await cli([command]);
      expect(result.exitCode, 2);
      expect(result.stderr, contains('USAGE_ERROR'));
    }
  });
  test('invalid options and positional arguments fail', () async {
    for (final arguments in [
      ['doctor', '--unknown'],
      ['doctor', 'unexpected'],
      ['nonsense'],
    ]) {
      final result = await cli(arguments);
      expect(result.exitCode, 2);
      expect(result.stderr, contains('USAGE_ERROR'));
    }
  });
  test(
    'build derives its policy from the project; a request needs --production',
    () async {
      final temp = await Directory.systemTemp.createTemp('cli-policy-');
      final pubspec = File('${temp.path}/pubspec.yaml')
        ..writeAsStringSync('name: app\nversion: 1.0.0+3\n');
      File('${temp.path}/android/app/build.gradle.kts')
        ..createSync(recursive: true)
        ..writeAsStringSync(
          'android { defaultConfig { applicationId = "com.example.app" } }',
        );
      Future<ProcessResult> build([List<String> extra = const []]) => cli([
        'build',
        'android',
        '--project',
        temp.path,
        ...extra,
        '--out',
        '${temp.path}/out',
      ]);
      final derived = await build();
      final named = await build(['--application-id', 'com.example.app']);
      pubspec.writeAsStringSync('name: app\nversion: 1.0.0\n');
      final unnumbered = await build();
      final publish = await cli(['publish', '--request', pubspec.path]);
      await temp.delete(recursive: true);
      for (final result in [derived, named]) {
        expect(result.exitCode, 2);
        // The policy came from the project; only its keys are missing.
        expect(result.stderr, contains('KEYS_MISSING'));
      }
      expect(unnumbered.stderr, contains('build number'));
      expect(publish.exitCode, 2);
      expect(publish.stderr, contains('PUBLISH_CONFIG_INVALID'));
    },
    skip: HostIdentity.verified.contains(HostIdentity.current().key)
        ? false
        : 'Needs a supported host',
  );
  test(
    'unsupported host emits a structured failure',
    () async {
      final result = await cli(['doctor', '--json', '--offline']);
      expect(result.exitCode, 1);
      final report = jsonDecode(result.stdout as String) as Map;
      expect(jsonEncode(report), contains('HOST_UNSUPPORTED'));
    },
    skip: HostIdentity.verified.contains(HostIdentity.current().key)
        ? 'Runs only on hosts outside the supported matrix'
        : false,
  );
  test('verified hosts pass the gate; others are refused with the matrix', () {
    expect(HostIdentity.verified, containsAll(['linux-x64', 'windows-x64']));
    expect(HostIdentity.implemented, containsAll(HostIdentity.verified));
    if (HostIdentity.verified.contains(HostIdentity.current().key)) {
      expect(requireSupportedHost().key, HostIdentity.current().key);
    } else {
      expect(
        requireSupportedHost,
        throwsA(
          isA<Failure>().having((e) => e.code, 'code', 'HOST_UNSUPPORTED'),
        ),
      );
    }
  });
  test('each host is verified for its own platforms', () {
    Matcher refused(String text) => throwsA(
      isA<Failure>()
          .having((e) => e.code, 'code', 'HOST_UNSUPPORTED')
          .having((e) => e.message, 'message', contains(text)),
    );
    for (final host in const [
      HostIdentity('linux', 'x64'),
      HostIdentity('windows', 'x64'),
      HostIdentity('macos', 'arm64'),
    ]) {
      expect(requireSupportedHost(host: host, environment: {}), host);
      for (final target in ['android', 'ios']) {
        expect(
          requireSupportedHost(target: target, host: host, environment: {}),
          host,
        );
      }
    }
    expect(
      () => requireSupportedHost(
        host: const HostIdentity('linux', 'arm64'),
        environment: {},
      ),
      refused('Supported build hosts'),
    );
    // The maintainer switch brings up implemented hosts only.
    expect(
      () => requireSupportedHost(
        target: 'android',
        host: const HostIdentity('linux', 'arm64'),
        environment: {'FLUTTER_PATCHER_UNVERIFIED_HOST': '1'},
      ),
      refused('Supported build hosts'),
    );
  });
}
