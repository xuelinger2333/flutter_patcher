import 'dart:io';
import 'package:flutter_patcher/src/cli/build/pins.dart';
import 'package:flutter_patcher/src/cli/core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test('native capability pins its forward closure; the rest stays free',
      () async {
    final root = (await Directory.systemTemp.createTemp('pins-')).path;
    addTearDown(() => Directory(root).delete(recursive: true));
    final packages = {
      'app': 'dependencies:\n  plugin_a: any\n  ffi_b: any\n  free_c: any\n',
      'plugin_a':
          'dependencies:\n  http: any\nflutter:\n  plugin:\n    platforms: {}\n',
      'ffi_b': '',
      'http': 'dependencies:\n  crypto: any\n',
      'crypto': '',
      'free_c': 'dependencies:\n  crypto: any\n  util_d: any\n',
      'util_d': '',
      'dev_only': '',
    };
    final rows = [];
    for (final e in packages.entries) {
      final dir = p.join(root, e.key);
      await Directory(p.join(dir, 'lib')).create(recursive: true);
      await File(p.join(dir, 'pubspec.yaml'))
          .writeAsString('name: ${e.key}\n${e.value}');
      rows.add({
        'name': e.key,
        'rootUri': Directory(dir).uri.toString(),
        'packageUri': 'lib/'
      });
    }
    await File(p.join(root, 'ffi_b', 'lib', 'b.dart'))
        .writeAsString("import 'dart:ffi';\n");
    final config = p.join(root, 'package_config.json');
    await writeObject(config, {'configVersion': 2, 'packages': rows});
    final pins = await computePackagePins(config, 'app');
    expect(pins.pinned.keys, ['crypto', 'ffi_b', 'http', 'plugin_a']);
    expect(pins.pinned['plugin_a'], {'reason': 'plugin'});
    expect(pins.pinned['ffi_b'], {'reason': 'ffi'});
    // A pure-Dart package is pinned because a plugin reaches it.
    expect(pins.pinned['crypto'], {
      'reason': 'dependency',
      'via': ['plugin_a', 'http', 'crypto']
    });
    expect(pins.free, {'free_c', 'util_d'});
  });
}
