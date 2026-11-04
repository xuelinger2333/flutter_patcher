import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';

import 'host_tools.dart';
import 'signers.dart';

import 'package:path/path.dart' as p;
import 'package:archive/archive.dart';
import 'package:flutter_patcher/src/bootstrap/patch_archive.dart';
import 'package:flutter_patcher/src/cli/core.dart';
import 'package:flutter_patcher/src/cli/patch/sources.dart';
import 'package:flutter_patcher/src/cli/patch/package.dart';
import 'package:flutter_patcher/src/cli/publish/seal.dart';
import 'package:flutter_patcher/src/cli/keys/bundle.dart';
import 'package:flutter_patcher/src/cli/sdk/package_inputs.dart';

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
  test('a URI split into adjacent literals is remapped as one', () {
    const source =
        "import 'package:app'\n    '/a.dart' as a show A;\n"
        "import 'package:host' '/h.dart';";
    final result = rewriteImports(source, {'app': 'patch.5.app'});
    expect(
      result,
      contains("import 'package:patch.5.app/a.dart' as a show A;"),
    );
    expect(result, contains("import 'package:host' '/h.dart';"));
  });
  test(
    'package URI rewriting copies source and does not rewrite host dependency',
    () async {
      final root = (await Directory.systemTemp.createTemp('patch-remap-')).path;
      for (final name in ['app', 'host']) {
        await Directory(p.join(root, name, 'lib')).create(recursive: true);
        await File(p.join(root, name, 'lib/main.dart')).writeAsString(
          "import 'package:app/a.dart'; import 'package:host/a.dart';",
        );
      }
      final config = p.join(root, 'config.json');
      await writeObject(config, {
        'configVersion': 2,
        'packages': [
          for (final name in ['app', 'host'])
            {
              'name': name,
              'rootUri': Directory(p.join(root, name)).uri.toString(),
              'packageUri': 'lib/',
            },
        ],
      });
      final output = await remapSources(config, p.join(root, 'module'), {
        'app',
      }, 3);
      expect((output['names'] as Map)['app'], 'patch.3.app');
      expect(
        await File(p.join(root, 'module/app/main.dart')).readAsString(),
        contains('package:host/a.dart'),
      );
      expect(
        await File(p.join(root, 'app/lib/main.dart')).readAsString(),
        contains('package:app/a.dart'),
      );
    },
  );
  test('native package provenance sees changes outside Dart sources', () async {
    final root = (await Directory.systemTemp.createTemp('patch-native-')).path;
    await File(
      p.join(root, 'pubspec.yaml'),
    ).writeAsString('name: plugin\nversion: 1.0.0\nflutter:\n  plugin: {}\n');
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
          'packageUri': 'lib/',
        },
      ],
    });
    final before = await packageInputs(config);
    final generated = File(p.join(root, 'android/.cxx/Release/CMakeCache.txt'));
    await generated.parent.create(recursive: true);
    await generated.writeAsString('machine-specific generated paths');
    expect(await packageInputs(config), before);
    final cmake = File(p.join(root, 'android/CMakeLists.txt'));
    await cmake.writeAsString('add_library(plugin SHARED Plugin.cpp)');
    final withCmake = await packageInputs(config);
    expect(jsonEncode(withCmake), isNot(jsonEncode(before)));
    await cmake.writeAsString('add_library(plugin SHARED Changed.cpp)');
    expect(
      jsonEncode(await packageInputs(config)),
      isNot(jsonEncode(withCmake)),
    );
    final beforeNative = await packageInputs(config);
    await native.writeAsString('changed');
    final after = await packageInputs(config);
    expect(jsonEncode(beforeNative), isNot(jsonEncode(after)));
    expect(after['plugin']['native'], true);
    expect(after['plugin'].containsKey('dart_files'), false);
    await File(p.join(root, 'lib/src/unused.dart')).create(recursive: true);
    final app = await packageInputs(config, application: 'plugin');
    expect((app['plugin']['dart_files'] as Map).keys, ['src/unused.dart']);
  });
  test(
    'real Ed25519 envelope verifies and detects tampering without a private file',
    () async {
      final root = (await Directory.systemTemp.createTemp('patch-sign-')).path;
      final commands = Commands(root);
      final signer = testSigner(
        base64Encode(List.filled(32, 1)),
        KeyRole.patch,
      );
      final module = File(p.join(root, 'module.bc'));
      await module.writeAsString(
        'explicit synthetic bytecode for envelope contract only',
      );
      final draft = await packPatch(
        kind: 'bytecode',
        code: module.path,
        metadata: {'fingerprint': 'a' * 64, 'module_id': 123, 'tier': 'lean'},
      );
      final bytes = await sealPatch(draft, signer: signer, seq: 7);
      final header = ByteData.sublistView(bytes);
      expect(header.getUint32(0), 0x46505443);
      expect(header.getUint16(4), 1);
      expect(header.getUint32(38), 7);
      expect(header.getUint64(42), bytes.length - 146);
      expect(
        ZipDecoder()
            .decodeBytes(bytes.sublist(146))
            .every((f) => f.compression == CompressionType.none),
        true,
      );
      // The device's strict reader accepts what the CLI writes.
      expect(readPatchArchive(Uint8List.sublistView(bytes, 146)).keys, [
        'module.bc',
        'patch_manifest.json',
      ]);
      // Numbering leaves the draft unchanged; resumed sealing is deterministic.
      expect(draft.manifest.containsKey('patch_seq'), false);
      final manifest = jsonDecode(
        utf8.decode(
          readPatchArchive(
            Uint8List.sublistView(bytes, 146),
          )['patch_manifest.json']!,
        ),
      ) as Map;
      expect(manifest['module_id'], 123);
      expect(manifest['patch_seq'], 7);
      expect(await sealPatch(draft, signer: signer, seq: 7), bytes);
      // An independent verifier rejects a damaged envelope.
      final signed = File(p.join(root, 'signed.bin'))
        ..writeAsBytesSync(
          [...bytes.sublist(0, 82), ...bytes.sublist(146)]..last ^= 1,
        );
      File(p.join(root, 'signature.bin'))
          .writeAsBytesSync(bytes.sublist(82, 146));
      File(p.join(root, 'signing-public.der')).writeAsBytesSync([
        ...hexBytes('302a300506032b6570032100'),
        ...base64Decode(signer.publicKey),
      ]);
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
        p.join(root, 'signature.bin'),
      ]);
      expect(check.exitCode, isNot(0));
    },
    tags: 'openssl',
    skip: skipUnless('openssl') ?? false,
  );
}
