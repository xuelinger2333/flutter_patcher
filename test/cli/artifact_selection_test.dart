import 'package:test/test.dart';
import 'package:flutter_patcher/src/cli/core.dart';
import 'package:flutter_patcher/src/cli/baseline/resolve.dart';
import 'package:flutter_patcher/src/cli/patch/pipeline.dart';

ResolvedRelease release(Map<String, dynamic> receipt) => ResolvedRelease(
  format: 'release',
  flavor: 'default',
  versionCode: '1',
  abi: 'arm64-v8a',
  fingerprint: '0' * 64,
  compileRoot: '',
  releaseRoot: '',
  compile: const {},
  receipt: receipt,
);

void main() {
  test('a patch uses the releases its host recorded', () {
    final releases = builtWith(
      release({
        'artifacts': {
          'engine': {
            'tag': 'engine-3.47.2-930ce683',
            'manifest_sha256': 'a' * 64,
          },
          'tools': {
            'tag': 'tools-3.47.2-6427c8dd',
            'manifest_sha256': 'b' * 64,
          },
        },
      }),
    );
    expect(
      {for (final r in releases) r.kind: r.tag},
      {'engine': 'engine-3.47.2-930ce683', 'tools': 'tools-3.47.2-6427c8dd'},
    );
  });
  test('a host built before releases were recorded must be rebuilt', () {
    for (final receipt in [
      <String, dynamic>{},
      {'artifacts': null},
      {'artifacts': {}},
    ]) {
      expect(
        () => builtWith(release(receipt)),
        throwsA(
          isA<Failure>().having(
            (e) => e.code,
            'code',
            'BASELINE_ARTIFACTS_MISSING',
          ),
        ),
      );
    }
  });
}
