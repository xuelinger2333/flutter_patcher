import 'dart:convert';
import 'dart:io';

import 'package:flutter_patcher/src/cli/patch/hooks.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test(
    'the bundle step sees hook packages without hook/, then the real config',
    () async {
      final temp = await Directory.systemTemp.createTemp('hooks-');
      addTearDown(() => temp.delete(recursive: true));
      Future<void> write(String path, String text) async =>
          File(p.join(temp.path, path))
              .create(recursive: true)
              .then((f) => f.writeAsString(text));
      await write('pub/native/lib/native.dart', 'void f() {}');
      await write('pub/native/hook/build.dart', 'void main() {}');
      await write('pub/plain/lib/plain.dart', 'void g() {}');
      final config = p.join(temp.path, 'app/.dart_tool/package_config.json');
      final text = jsonEncode({
        'configVersion': 2,
        'packages': [
          {
            'name': 'native',
            'rootUri': '../../pub/native',
            'packageUri': 'lib/',
          },
          {
            'name': 'plain',
            'rootUri': '../../pub/plain/',
            'packageUri': 'lib/',
          },
        ],
      });
      await write('app/.dart_tool/package_config.json', text);
      final seen = await withoutBuildHooks(
        config,
        p.join(temp.path, 'shadow'),
        () async {
          final rows = {
            for (final row
                in (jsonDecode(await File(config).readAsString())['packages']
                    as List))
              row['name']: Uri.parse(row['rootUri'] as String),
          };
          final native = Directory.fromUri(rows['native']!);
          return [
            await File(p.join(native.path, 'lib/native.dart')).exists(),
            await Directory(p.join(native.path, 'hook')).exists(),
            rows['plain'].toString(),
          ];
        },
      );
      expect(seen, [true, false, '../../pub/plain/']);
      expect(await File(config).readAsString(), text);
    },
  );
}
