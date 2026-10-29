import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:flutter_patcher_cli/src/core.dart';
import 'package:flutter_patcher_cli/src/sdk/host.dart';

void main() {
  Future<ProcessResult> cli(List<String> args) => Process.run(
      Platform.resolvedExecutable, ['bin/flutter_patcher.dart', ...args]);

  test('help and version are usable without Flutter or a network', () async {
    final help = await cli(['--help']);
    expect(help.exitCode, 0);
    expect(help.stdout, contains('flutter_patcher doctor'));
    final version = await cli(['--version']);
    expect(version.exitCode, 0);
    expect(version.stdout, contains('2.0.0-dev.1'));
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
      ['nonsense']
    ]) {
      final result = await cli(arguments);
      expect(result.exitCode, 2);
      expect(result.stderr, contains('USAGE_ERROR'));
    }
  });
  test('build needs a host policy and publish is production-only', () async {
    final temp = await Directory.systemTemp.createTemp('cli-policy-');
    final key = File('${temp.path}/public.base64')..writeAsStringSync('k');
    final build = await cli([
      'build',
      'android',
      '--public-key',
      key.path,
      '--out',
      '${temp.path}/out'
    ]);
    final publish = await cli(['publish', '--request', key.path]);
    await temp.delete(recursive: true);
    expect(build.exitCode, 2);
    expect(build.stderr, contains('Missing --host-policy'));
    expect(publish.exitCode, 2);
    expect(publish.stderr, contains('PUBLISH_CONFIG_INVALID'));
  },
      skip: HostIdentity.verified.contains(HostIdentity.current().key)
          ? false
          : 'Needs a supported host');
  test('unsupported host emits a structured failure', () async {
    final result = await cli(['doctor', '--json', '--offline']);
    expect(result.exitCode, 1);
    final report = jsonDecode(result.stdout as String) as Map;
    expect(jsonEncode(report), contains('HOST_UNSUPPORTED'));
  },
      skip: HostIdentity.verified.contains(HostIdentity.current().key)
          ? 'Runs only on hosts outside the supported matrix'
          : false);
  test('verified hosts pass the gate; others are refused with the matrix', () {
    expect(HostIdentity.verified, containsAll(['linux-x64', 'windows-x64']));
    expect(HostIdentity.implemented, containsAll(HostIdentity.verified));
    if (HostIdentity.verified.contains(HostIdentity.current().key)) {
      expect(requireSupportedHost().key, HostIdentity.current().key);
    } else {
      expect(
          requireSupportedHost,
          throwsA(isA<Failure>()
              .having((e) => e.code, 'code', 'HOST_UNSUPPORTED')));
    }
  });
}
