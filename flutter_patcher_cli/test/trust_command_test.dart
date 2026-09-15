import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:flutter_patcher_cli/src/publish/trust_command.dart';
import 'package:flutter_patcher_cli/src/publish/store.dart';
import 'package:flutter_patcher_cli/src/core.dart';

void main() {
  test('root sign, atomic publish, retry, replay and namespace isolation',
      () async {
    final directory =
        await Directory('.dart_tool/flutter_patcher').create(recursive: true);
    final work = await directory.createTemp('trust-test-');
    final pub = File(p.join(work.path, 'public'));
    final secret = File(p.join(work.path, 'private'));
    List<int> hex(String value) => [
          for (var i = 0; i < value.length; i += 2)
            int.parse(value.substring(i, i + 2), radix: 16)
        ];
    await pub.writeAsString(base64Encode(hex(
        'd75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a')));
    await secret.writeAsString(base64Encode(hex(
        '9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60')));
    final fields = {
      'schema': '1',
      'application_id': 'com.example.test',
      'version_code': '1',
      'abi': 'arm64-v8a',
      'channel': 'stable',
      'flavor': 'default',
      'fingerprint': 'a' * 64,
      'strategy': 'bytecode',
      'revision': '1',
      'keys': '-'
    };
    final payload = File(p.join(work.path, 'fields.json'));
    final store = FilePublishStore(p.join(work.path, 'store'));
    final common = ['--root-public', pub.path, '--cache-dir', work.path];
    Future<String> sign(String name, Map<String, String> value) async {
      await payload.writeAsString(jsonEncode(value));
      final wire = p.join(work.path, name);
      await trustCommand(trustOptions().parse([
        'sign',
        ...common,
        '--root-private',
        secret.path,
        '--fields',
        payload.path,
        '--out',
        wire
      ]));
      return wire;
    }

    Future<int> publish(String wire) => trustCommand(trustOptions().parse([
          'publish',
          ...common,
          '--wire',
          wire,
          '--store',
          Directory(store.root).uri.toString()
        ]));
    final first = await sign('first.json', fields);
    expect(await publish(first), 0);
    expect(await publish(first), 0);
    final next = await sign('next.json', {...fields, 'revision': '2'});
    expect(await publish(next), 0);
    await expectLater(publish(first), throwsA(isA<Failure>()));
    final wrongScope = await sign(
        'wrong.json', {...fields, 'revision': '3', 'channel': 'beta'});
    await expectLater(publish(wrongScope), throwsA(isA<Failure>()));
    expect(utf8.decode((await store.read('trust.json'))!.bytes),
        await File(next).readAsString());
    await expectLater(store.delete('trust.json'), throwsA(isA<Failure>()));
  }, skip: !Platform.isLinux ? 'Requires Linux/OpenSSL' : false);
}
