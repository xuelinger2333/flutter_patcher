import 'package:flutter_patcher/src/cli/core.dart';
import 'package:flutter_patcher/src/cli/patch/pipeline.dart';
import 'package:flutter_patcher/src/cli/patch/rules.dart';
import 'package:test/test.dart';

PatchFacts facts() => PatchFacts('bytecode', 'android', 'work');

void main() {
  test('compareInputs records old and new versions of a drifted dependency',
      () {
    final f = facts();
    compareInputs(
      {
        'app': {'native_files': {}},
        'free_c': {'version': '2.0.0'},
      },
      {
        'app': {'native_files': {}},
        'free_c': {'version': '1.0.0'},
      },
      'app',
      f,
    );
    expect(
      f.dependencyDrift['free_c'],
      (released: '1.0.0', current: '2.0.0'),
    );
  });

  test('a whole-tier failure after drift names the drift and the check', () {
    final f = facts()
      ..tier = 'whole'
      ..dependencyDrift['free_c'] = (released: '1.0.0', current: '2.0.0')
      ..report = {
        'status': 'rejected',
        'checks': {
          'uris': [
            {
              'message':
                  'Target of URI does not exist: package:free_c/src/old.dart',
            },
          ],
        },
      };
    expect(
      () => PatchRules().check(PatchStage.code, f),
      throwsA(
        isA<Failure>()
            .having((e) => e.code, 'code', 'PATCH_UNSAFE')
            .having(
              (e) => e.message,
              'message',
              allOf(
                contains('free_c'),
                contains('1.0.0'),
                contains('2.0.0'),
                contains('uris:'),
              ),
            ),
      ),
    );
  });

  test('a whole-tier failure without drift keeps the plain check message',
      () {
    final f = facts()
      ..tier = 'whole'
      ..report = {
        'status': 'rejected',
        'checks': {
          'uris': [{'message': 'bad file'}],
        },
      };
    expect(
      () => PatchRules().check(PatchStage.code, f),
      throwsA(
        isA<Failure>().having(
          (e) => e.message,
          'message',
          isNot(contains('Dependency versions changed')),
        ),
      ),
    );
  });
}
