import 'dart:io';
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

void main() {
  test(
      'acceptance workflow parses and separates public tests from trusted devices',
      () {
    final workflow =
        loadYaml(File('../.github/workflows/ci.yml').readAsStringSync())
            as YamlMap;
    expect(workflow['permissions']['contents'], 'read');
    final jobs = workflow['jobs'] as YamlMap;
    expect(jobs.keys,
        containsAll(['versions', 'fast', 'host_a', 'host_b_device']));
    expect(jobs['host_a']['if'], contains("github.event_name == 'push'"));
    expect(jobs['host_a']['if'],
        isNot(contains("github.event_name == 'pull_request'")));
    expect(jobs['host_b_device']['needs'], contains('host_a'));
    expect(
        workflow['on']['workflow_dispatch']['inputs']['full_acceptance']
            ['default'],
        false);
    for (final job in jobs.values) {
      for (final step in job['steps'] as YamlList) {
        if (step['uses'] is String) {
          expect(step['uses'], matches(RegExp(r'@[a-f0-9]{40}$')));
        }
      }
    }
  });
}
