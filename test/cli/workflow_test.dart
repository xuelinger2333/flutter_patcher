import 'dart:io';

import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

void main() {
  test('CI is read-only, hosted-only and pins every action', () {
    final workflow = loadYaml(
      File('.github/workflows/ci.yml').readAsStringSync(),
    ) as YamlMap;
    expect(workflow['permissions']['contents'], 'read');
    final jobs = workflow['jobs'] as YamlMap;
    expect(jobs.keys, containsAll(['versions', 'fast']));
    for (final job in jobs.values) {
      // Pull requests must never reach a trusted machine.
      expect('${job['runs-on']}', isNot(contains('self-hosted')));
      for (final step in job['steps'] as YamlList) {
        if (step['uses'] is String) {
          expect(step['uses'], matches(RegExp(r'@[a-f0-9]{40}$')));
        }
      }
    }
  });
}
