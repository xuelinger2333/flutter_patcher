import 'package:flutter_patcher/src/cli/build/workspace.dart';
import 'package:test/test.dart';

void main() {
  test('generated directories are skipped only where tools create them', () {
    for (final path in [
      'build',
      'android/app/build',
      'ios/Pods',
      'ios/.symlinks',
      'windows/flutter/ephemeral',
      'lib/x/.dart_tool',
      'a/.git',
    ]) {
      expect(BuildWorkspace.skipped(path), isTrue, reason: path);
    }
    for (final path in [
      'lib/features/build',
      'assets/build',
      'lib/Pods',
      'lib/ephemeral',
      'packages/x/build',
    ]) {
      expect(BuildWorkspace.skipped(path), isFalse, reason: path);
    }
  });
}
