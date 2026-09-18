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
  test('unsupported host emits a structured failure', () async {
    final result = await cli(['doctor', '--json', '--offline']);
    expect(result.exitCode, 1);
    final report = jsonDecode(result.stdout as String) as Map;
    expect(jsonEncode(report), contains('HOST_UNSUPPORTED'));
  },
      skip: HostIdentity.verified.contains(HostIdentity.current().key)
          ? 'Runs only on hosts outside the WP-2.6 matrix'
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
