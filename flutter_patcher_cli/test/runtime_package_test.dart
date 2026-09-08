import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:flutter_patcher_cli/src/build/bootstrap.dart';
import 'package:flutter_patcher_cli/src/build/runtime_package.dart';
import 'package:flutter_patcher_cli/src/core.dart';

void main() {
  test('runtime wrapper has stable source and lives only under isolated config',
      () async {
    final root = await Directory.systemTemp.createTemp('wp8-runtime-');
    final sources = <String>[];
    for (final sub in ['build', 'patch']) {
      final config = p.join(root.path, sub, '.dart_tool/package_config.json');
      await File(config).parent.create(recursive: true);
      await writeObject(config, {'configVersion': 2, 'packages': []});
      await installRuntimePackage(config, 'demo', 'main.dart');
      final rows = (await readObject(config))['packages'] as List;
      expect(rows.single['name'], 'dynamic_modules');
      final uri = Uri.parse(rows.single['rootUri'] as String);
      expect(p.isWithin(File(config).parent.path, uri.toFilePath()), isTrue);
      sources
          .add(await File.fromUri(uri.resolve('lib/host.dart')).readAsString());
      final loader = await File.fromUri(uri.resolve('lib/dynamic_modules.dart'))
          .readAsString();
      expect(loader, contains('internal.loadDynamicModule(bytes: bytes)'));
      await expectLater(installRuntimePackage(config, 'demo', 'main.dart'),
          throwsA(isA<Failure>()));
    }
    expect(sources[0], sources[1]);
    final source = bootstrapSource('demo', 'main.dart', 'a' * 64,
        'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=');
    expect(source, contains('loadModule: loadModule'));
    expect(source, isNot(contains('ensureInitialized')));
  });
}
