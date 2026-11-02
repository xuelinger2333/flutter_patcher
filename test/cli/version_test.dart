import 'dart:io';
import 'package:flutter_patcher/src/cli/version.dart';
import 'package:test/test.dart';

void main() {
  test('the CLI reports the package version', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    expect(RegExp(r'^version:\s*(\S+)', multiLine: true).firstMatch(pubspec)![1],
        packageVersion);
  });
}