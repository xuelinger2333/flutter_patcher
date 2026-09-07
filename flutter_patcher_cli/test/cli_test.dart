import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';

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
  test('later work packages fail explicitly', () async {
    for (final command in ['build', 'patch', 'publish', 'keys']) {
      final result = await cli([command]);
      expect(result.exitCode, 2);
      expect(result.stderr, contains('COMMAND_NOT_IMPLEMENTED'));
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
  }, skip: Platform.isLinux);
}
