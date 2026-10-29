import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:flutter_patcher_cli/src/legacy/mock_server.dart' as mock;
import 'package:flutter_patcher_cli/src/legacy/pack.dart';
import 'package:flutter_patcher_cli/src/patch/resources.dart';

void main() {
  late Directory temp;
  late String apk;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('legacy-tools-');
    final archive = Archive();
    void add(String name, List<int> bytes) =>
        archive.addFile(ArchiveFile(name, bytes.length, bytes));
    add('lib/arm64-v8a/libapp.so', utf8.encode('libapp'));
    add('assets/flutter_assets/images/a.png', utf8.encode('png'));
    add(
        'assets/flutter_assets/AssetManifest.bin',
        AssetCodec.encode({
          'images/a.png': [
            {'asset': 'images/a.png'}
          ]
        }));
    apk = p.join(temp.path, 'app-release.apk');
    await File(apk).writeAsBytes(ZipEncoder().encode(archive));
  });
  tearDown(() => temp.delete(recursive: true));
  List<String> args(String out, [List<String> extra = const []]) =>
      ['--apk', apk, '--version', '1.0.0-h1', '--target-version-code', '100', '--out', out, ...extra];

  test('pack writes a v2 package that mock-server serves', () async {
    final dist = p.join(temp.path, 'dist');
    expect(await packMain(args(dist, ['--assets', 'images/a.png'])), 0);
    final bytes = await File(p.join(dist, 'patch.zip')).readAsBytes();
    final zip = ZipDecoder().decodeBytes(bytes);
    expect(utf8.decode(zip.findFile('assets/images/a.png')!.content), 'png');
    final ops = jsonDecode(utf8.decode(zip.findFile('manifest_patch.json')!.content));
    expect(ops['operations'].single['key'], 'images/a.png');

    final patch = await mock.loadMockPatch(dist: dist);
    expect(patch.md5, md5.convert(bytes).toString());
    final server = await mock.startMockPatchServer(
        mock.MockPatchServerConfig(patch: patch, host: '127.0.0.1', port: 0));
    addTearDown(() => server.close(force: true));
    final client = HttpClient();
    addTearDown(client.close);
    Future<List<int>> get(String path) async {
      final response =
          await (await client.getUrl(Uri.parse('http://127.0.0.1:${server.port}$path'))).close();
      return [await for (final chunk in response) ...chunk];
    }

    final check = jsonDecode(utf8.decode(await get('/check')));
    expect(check['patch']['patchUrl'], 'http://127.0.0.1:${server.port}/patch.zip');
    expect(await get('/patch.zip'), bytes);
  });

  test('pack rejects unknown asset keys and nested list includes', () async {
    expect(await packMain(args(p.join(temp.path, 'a'), ['--assets', 'images/none.png'])), 65);
    final list = File(p.join(temp.path, 'list.txt'))..writeAsStringSync('# keys\n@other.txt\n');
    expect(await packMain(args(p.join(temp.path, 'b'), ['--assets', '@${list.path}'])), 65);
  });
}