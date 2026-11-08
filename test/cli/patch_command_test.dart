import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'package:flutter_patcher/src/cli/keys/bundle.dart';
import 'package:flutter_patcher/src/cli/patch/package.dart';
import 'package:flutter_patcher/src/cli/patch_command.dart';
import 'package:flutter_patcher/src/cli/project.dart';
import 'package:flutter_patcher/src/patch_file.dart';

/// What `patch` adds to its draft: the file devices take,
/// plan/1.1-direct-patching.md §4.5.
void main() {
  late Directory root;
  late String output;
  final scope = {
    'application_id': 'com.example.app',
    'channel': 'beta',
    'flavor': 'paid',
    'version_code': '12',
    'abi': 'arm64-v8a',
    'fingerprint': 'cd' * 32,
    'strategy': 'bytecode',
  };
  setUp(() async {
    root = await Directory.systemTemp.createTemp('patch-command-');
    output = p.join(root.path, 'out');
    final module = File(p.join(root.path, 'module.bc'))..writeAsStringSync('x');
    final draft = await packPatch(
      kind: 'bytecode',
      code: module.path,
      metadata: {'fingerprint': 'cd' * 32, 'module_id': 3, 'tier': 'lean'},
    );
    await Directory(output).create();
    await draft.write(output);
  });
  tearDown(() => root.delete(recursive: true));

  Map<String, Object?> result(String patchKey) => {
    'status': 'patch_created',
    'output': output,
    'scope': scope,
    'patch_key': patchKey,
  };

  test('an unsigned host gets <output>/<fileName>, numbered now', () async {
    final before = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final sealed = await sealOutput(
      result('-'),
      await ProjectConfig.load(root.path),
    );
    final file = File(sealed['file'] as String);
    expect(p.basename(file.path), '12-paid-beta-arm64-v8a.fptc');
    expect(p.dirname(file.path), output);
    final header = PatchHeader.parse(file.readAsBytesSync());
    expect(header.seq, sealed['seq']);
    expect(header.seq, greaterThanOrEqualTo(before));
    expect(header.fingerprint, 'cd' * 32);
    expect(sealed['signed'], isFalse);
    expect(
      DateTime.parse(sealed['sealed_at'] as String).millisecondsSinceEpoch,
      header.seq * 1000,
    );
  });

  test('a signed host whose key is not here gets only the draft', () async {
    final sealed = await sealOutput(
      result(KeyBundle.generate().publicKey),
      await ProjectConfig.load(root.path),
    );
    expect(sealed['file'], isNull);
    expect(sealed['notice'], contains('publish'));
    expect(
      Directory(output).listSync().where((e) => e.path.endsWith('.fptc')),
      isEmpty,
    );
    expect(await PatchDraft.read(output), isA<PatchDraft>());
  });
}
