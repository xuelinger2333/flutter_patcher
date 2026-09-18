import 'package:flutter_patcher_cli/src/cli.dart';
import 'package:flutter_patcher_cli/src/patch/tier_policy.dart';
import 'package:test/test.dart';

void main() {
  test('normal build and patch select bytecode; explicit SO remains accepted',
      () {
    for (final command in ['build', 'patch']) {
      expect(parser().parse([command, 'android']).command!['strategy'],
          'bytecode');
      expect(
          parser().parse(
              [command, 'android', '--strategy', 'so']).command!['strategy'],
          'so');
    }
  });

  test('framework reuse is on by default and can be disabled per command', () {
    for (final command in ['build', 'patch']) {
      expect(
          parser().parse([command, 'android']).command!['no-framework-reuse'],
          false);
      expect(
          parser().parse([command, 'android', '--no-framework-reuse']).command![
              'no-framework-reuse'],
          true);
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
