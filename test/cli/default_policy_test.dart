import 'package:flutter_patcher/src/cli/cli.dart';
import 'package:test/test.dart';

void main() {
  test('the host policy, not an option, selects the strategy', () {
    for (final command in ['build', 'patch']) {
      expect(() => parser().parse([command, 'android', '--strategy', 'so']),
          throwsFormatException);
    }
  });

  test('the removed framework reuse flag is rejected', () {
    for (final command in ['build', 'patch']) {
      expect(() => parser().parse([command, 'android', '--framework-reuse']),
          throwsFormatException);
    }
  });
}
