import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'package:flutter_patcher/src/cli/build/command.dart';
import 'package:flutter_patcher/src/cli/build/host_policy.dart';

/// What `build` prints: the app to install and the host it is, in a line a
/// person can read; the whole report stays in build.json beside the app.
void main() {
  late Directory output;
  setUp(() async {
    output = await Directory.systemTemp.createTemp('build-summary-');
    File(p.join(output.path, 'app-release.apk')).writeAsStringSync('apk');
    File(p.join(output.path, 'build.json')).writeAsStringSync('{}');
  });
  tearDown(() => output.delete(recursive: true));

  HostPolicy policy(String key) => HostPolicy({
    'schema': '2',
    'strategy': 'bytecode',
    'abi': 'arm64-v8a',
    'application_id': 'com.example.app',
    'version_code': '3',
    'flavor': 'default',
    'channel': 'production',
    'fptc_key': key,
  });

  final report = {
    'status': 'build_archived',
    'fingerprint': 'ab' * 32,
    'package_inputs': {for (var i = 0; i < 200; i++) 'package$i': 'x' * 64},
    'resources': {'files': {}},
  };

  test('names the app, the host and the report, and nothing more', () async {
    final summary = await buildSummary(output.path, report, policy('-'));
    expect(summary, {
      'command': 'build',
      'status': 'build_archived',
      'app': p.join(output.path, 'app-release.apk'),
      'application_id': 'com.example.app',
      'version_code': '3',
      'strategy': 'bytecode',
      'signed': false,
      'fingerprint': 'ab' * 32,
      'report': p.join(output.path, 'build.json'),
    });
    expect(jsonEncode(summary).length, lessThan(600));
  });

  test('says whether the host accepts only signed files', () async {
    final key = base64Encode(List.filled(32, 1));
    expect(
      (await buildSummary(output.path, report, policy(key)))['signed'],
      isTrue,
    );
  });
}
