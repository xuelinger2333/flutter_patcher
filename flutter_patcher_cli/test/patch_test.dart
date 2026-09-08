import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:path/path.dart' as p;
import 'package:archive/archive.dart';
import 'package:flutter_patcher_cli/src/core.dart';
import 'package:flutter_patcher_cli/src/patch/sources.dart';
import 'package:flutter_patcher_cli/src/patch/package.dart';
import 'package:flutter_patcher_cli/src/sdk/package_inputs.dart';

void main() {
  test('nested comments and runtime interpolation are not rewritten', () {
    const source =
        '/* outer /* nested */ import "package:app/comment.dart"; */\n'
        'import "package:app/a.dart";\n'
        'const text="import package:app/runtime.dart";';
    final result = rewriteImports(source, {'app': 'patch.2.app'});
    expect(result, contains('package:app/comment.dart'));
    expect(result, contains('package:app/runtime.dart'));
    expect(result, contains('package:patch.2.app/a.dart'));
  });
  test('only directive URIs are remapped, including conditional imports', () {
    const source =
        "// import 'package:app/fake.dart';\nimport 'package:app/a.dart' if (dart.library.io) 'package:app/b.dart';\n"
        "export 'package:app/c.dart';\nconst text='package:app/a.dart';";
    final result = rewriteImports(source, {'app': 'patch.4.app'});
    expect(result, contains("// import 'package:app/fake.dart'"));
    expect(result, contains("const text='package:app/a.dart'"));
    expect(result, contains("import 'package:patch.4.app/a.dart'"));
    expect(result, contains("'package:patch.4.app/b.dart'"));
  });
  test(
      'package URI rewriting copies source and does not rewrite host dependency',
      () async {
    final root = (await Directory.systemTemp.createTemp('wp6-remap-')).path;
    for (final name in ['app', 'host']) {
      await Directory(p.join(root, name, 'lib')).create(recursive: true);
      await File(p.join(root, name, 'lib/main.dart')).writeAsString(
          "import 'package:app/a.dart'; import 'package:host/a.dart';");
    }
    final config = p.join(root, 'config.json');
    await writeObject(config, {
      'configVersion': 2,
      'packages': [
        for (final name in ['app', 'host'])
          {
            'name': name,
            'rootUri': Directory(p.join(root, name)).uri.toString(),
            'packageUri': 'lib/'
          }
      ]
    });
    final output =
        await remapSources(config, p.join(root, 'module'), {'app'}, 3);
    expect((output['names'] as Map)['app'], 'patch.3.app');
    expect(await File(p.join(root, 'module/app/main.dart')).readAsString(),
        contains('package:host/a.dart'));
    expect(await File(p.join(root, 'app/lib/main.dart')).readAsString(),
        contains('package:app/a.dart'));
  });
  test('native package provenance sees changes outside Dart sources', () async {
    final root = (await Directory.systemTemp.createTemp('wp6-native-')).path;
    await File(p.join(root, 'pubspec.yaml')).writeAsString(
        'name: plugin\nversion: 1.0.0\nflutter:\n  plugin: {}\n');
    await Directory(p.join(root, 'android')).create();
    final native = File(p.join(root, 'android/Plugin.kt'));
    await native.writeAsString('original');
    final config = p.join(root, 'config.json');
    await writeObject(config, {
      'configVersion': 2,
      'packages': [
        {
          'name': 'plugin',
          'rootUri': Directory(root).uri.toString(),
          'packageUri': 'lib/'
        }
      ]
    });
    final before = await packageInputs(config);
    await native.writeAsString('changed');
    final after = await packageInputs(config);
    expect(jsonEncode(before), isNot(jsonEncode(after)));
    expect(after['plugin']['native'], true);
  });
  test(
      'real Ed25519 envelope verifies and detects tampering without a private file',
      () async {
    final root = (await Directory.systemTemp.createTemp('wp6-sign-')).path;
    final commands = Commands(root);
    final key =
        await signingKey(base64Encode(List.filled(32, 1)), root, commands);
    final module = File(p.join(root, 'module.bc'));
    await module.writeAsString(
        'explicit synthetic bytecode for envelope contract only');
    final result = await packPatch(
        module: module.path,
        work: root,
        metadata: {
          'format_version': 1,
          'fingerprint': 'a' * 64,
          'patch_seq': 7,
          'tier': 'lean'
        },
        key: key,
        commands: commands);
    final bytes = await File(result['file'] as String).readAsBytes();
    final header = ByteData.sublistView(bytes);
    expect(header.getUint32(0), 0x46505443);
    expect(header.getUint16(4), 1);
    expect(header.getUint32(38), 7);
    expect(header.getUint64(42), bytes.length - 146);
    expect(
        ZipDecoder()
            .decodeBytes(bytes.sublist(146))
            .every((f) => f.compression == CompressionType.none),
        true);
    expect(await File(p.join(root, 'signing-key.der')).exists(), false);
    final signed = File(p.join(root, 'signed.bin'));
    final damaged = await signed.readAsBytes();
    damaged.last ^= 1;
    await signed.writeAsBytes(damaged);
    final check = await commands.runResult('openssl', [
      'pkeyutl',
      '-verify',
      '-rawin',
      '-pubin',
      '-inkey',
      p.join(root, 'signing-public.der'),
      '-keyform',
      'DER',
      '-in',
      signed.path,
      '-sigfile',
      p.join(root, 'signature.bin')
    ]);
    expect(check.exitCode, isNot(0));
  }, skip: !Platform.isLinux);
}
