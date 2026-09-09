import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:test/test.dart';
import 'package:flutter_patcher_cli/src/mock/command.dart';
import 'package:flutter_patcher_cli/src/core.dart';

void main() {
  test('metadata binds exact bytes and refuses inconsistent envelopes', () {
    final data = ByteData(147)
      ..setUint32(0, 0x46505443)
      ..setUint16(4, 1)
      ..setUint32(38, 7)
      ..setUint64(42, 1);
    final bytes = data.buffer.asUint8List();
    bytes.setRange(50, 82, sha256.convert([0]).bytes);
    expect(mockMetadata(bytes, 1)['patch_seq'], 7);
    expect(mockMetadata(bytes, 1)['sha256'], sha256.convert(bytes).toString());
    bytes[146] = 1;
    expect(() => mockMetadata(bytes, 1), throwsA(isA<Failure>()));
    expect(() => mockMetadata(Uint8List(3), 1), throwsA(isA<Failure>()));
  });
  test('loopback mock supports update, withdrawal and immutable payload routes',
      () async {
    final root = await Directory.systemTemp.createTemp('patcher-mock-');
    final digest = 'ab' * 32;
    await File('${root.path}/$digest.fptc').writeAsBytes([1, 2]);
    await writeMockState(root.path, {
      'hasUpdate': true,
      'patch': {'sha256': digest}
    });
    final server = await serveMock(root.path, 0);
    final client = HttpClient();
    addTearDown(() async {
      client.close(force: true);
      await server.close(force: true);
      await root.delete(recursive: true);
    });
    Future<HttpClientResponse> get(String path) async =>
        (await client.getUrl(Uri.parse('http://127.0.0.1:${server.port}$path')))
            .close();
    final state = jsonDecode(await utf8.decodeStream(await get('/check')));
    expect(state['patch']['patchUrl'],
        'http://127.0.0.1:${server.port}/$digest.fptc');
    expect(
        await (await get('/$digest.fptc')).expand((b) => b).toList(), [1, 2]);
    await writeMockState(root.path, {'hasUpdate': false, 'rollback': true});
    expect(jsonDecode(await utf8.decodeStream(await get('/check')))['rollback'],
        true);
    final response = await get('/current.json');
    expect(response.statusCode, 404);
    await response.drain<void>();
  });
}
