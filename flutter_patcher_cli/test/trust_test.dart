import 'dart:convert';
import 'package:test/test.dart';
import 'package:flutter_patcher_cli/src/build/host_policy.dart';
import 'package:flutter_patcher_cli/src/baseline/manifest.dart';
import 'package:flutter_patcher_cli/src/publish/trust.dart';

void main() {
  final key = base64Encode(List.filled(32, 1));
  final policy = <String, String>{
    'schema': '1',
    'application_id': 'com.example.test',
    'version_code': '1',
    'channel': 'stable',
    'flavor': 'default',
    'abi': 'arm64-v8a',
    'strategy': 'bytecode',
    'fptc_key': key,
    'root_key': key,
    'keys': 'one:$key'
  };
  test('trust policy changes create a new baseline; legacy is stable', () {
    String identity([String? digest]) =>
        fingerprint('a' * 64, 'b' * 40, 'c' * 64, '3.47.2',
            hostPolicyHash: digest);
    final first = HostPolicy(policy);
    final next = HostPolicy({...policy, 'channel': 'beta'});
    expect(identity(first.digest), isNot(identity()));
    expect(identity(first.digest), isNot(identity(next.digest)));
    expect(HostPolicy.parse(first.canonical).digest, first.digest);
    expect(
        () => HostPolicy.parse('${first.canonical}\n'), throwsFormatException);
  });
  test('policy forbids unknown fields and invalid target/key inputs', () {
    for (final change in [
      {'verified': 'true'},
      {'strategy': 'so'},
      {'fptc_key': 'bad'},
      {'version_code': '01'},
      {'abi': 'x86_64'},
      {'keys': 'same:$key,same:$key'}
    ]) {
      expect(() => HostPolicy({...policy, ...change}), throwsFormatException);
    }
  });
  test('trust domain and complete key set grammar', () {
    final fields = {
      for (final k in TrustUpdate.scopeKeys)
        k: k == 'fingerprint' ? 'a' * 64 : policy[k]!,
      'schema': '1',
      'revision': '1',
      'keys': '-'
    };
    final update = TrustUpdate(fields);
    expect(utf8.decode(update.signingBytes),
        startsWith('flutter_patcher.trust.v1\n'));
    expect(TrustUpdate.parseKeys('-'), isEmpty);
    expect(() => TrustUpdate({...fields, 'keys': 'z:$key,a:$key'}),
        throwsFormatException);
    expect(() => TrustUpdate({...fields, 'revision': '9007199254740992'}),
        throwsFormatException);
    expect(() => TrustUpdate({...fields, 'key_id': 'self'}),
        throwsFormatException);
  });
}
