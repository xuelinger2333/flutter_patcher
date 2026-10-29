import 'package:flutter_patcher_cli/src/cli.dart';
import 'package:flutter_patcher_cli/src/patch/tier_policy.dart';
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

  test('any host reuse restriction requires a separately checked whole patch',
      () {
    for (final checked in [true, false]) {
      for (final dependencies in [false, true]) {
        for (final resources in [false, true]) {
          expect(
              selectPatchTier(
                  leanChecked: checked,
                  dependencyChanged: dependencies,
                  resourceUpgrade: resources),
              checked && !dependencies && !resources ? 'lean' : 'whole');
        }
      }
    }
  });
}
