import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:flutter_patcher_cli/src/core.dart';
import 'package:flutter_patcher_cli/src/sdk/artifacts.dart';
import 'package:flutter_patcher_cli/src/sdk/environment.dart';

class FakeCompiler extends Commands {
  int generators = 0;
  FakeCompiler(super.cache);
  @override
  Future<String> run(String executable, List<String> args,
      {String? cwd,
      String code = 'TOOL_FAILED',
      Duration timeout = const Duration(minutes: 15),
      Map<String, String>? extraEnvironment}) async {
    final index = args.indexOf('--out');
    final indexOutput = args.indexOf('--output-dill');
    if (indexOutput >= 0) {
      await File(args[indexOutput + 1]).writeAsString('linked-index');
    }
    if (index >= 0) {
      generators++;
      await File(args[index + 1])
          .writeAsString('callable:\n  - library: dart:core\n');
    }
    return '';
  }
}

void main() {
  test('YAML cache binds SDK source and tool hashes and repairs corruption',
      () async {
    final temp = await Directory.systemTemp.createTemp('wp2-yaml-');
    addTearDown(() => temp.delete(recursive: true));
    final root = p.join(temp.path, 'sdk');
    Future<File> seed(String relative, String text) async {
      final file = File(p.join(root, relative));
      await file.parent.create(recursive: true);
      await file.writeAsString(text);
      return file;
    }

    final source = await seed('packages/flutter/lib/a.dart', 'class A {}');
    await seed('packages/flutter/pubspec.yaml', 'name: flutter');
    await seed(
        'bin/cache/artifacts/engine/common/flutter_patched_sdk_product/platform_strong.dill',
        'platform');
    await seed(
        'bin/cache/artifacts/engine/linux-x64/frontend_server_aot.dart.snapshot',
        'compiler');
    final tool = await seed('tools.dill', 'tool v1');
    final sdk = SdkIdentity(root, '3.47.2', 'a' * 40, '3.13.2', 'b' * 40);
    final commands = FakeCompiler(temp.path);
    final builder = EnvironmentBuilder(p.join(temp.path, 'cache'), commands);
    final first = await builder.yamlCache(sdk, root, tool.path);
    expect(commands.generators, 2);
    expect(await builder.yamlCache(sdk, root, tool.path), first);
    expect(commands.generators, 2);
    await source.writeAsString('class A {} class B {}');
    final second = await builder.yamlCache(sdk, root, tool.path);
    expect(second, isNot(first));
    expect(commands.generators, 4);
    await tool.writeAsString('tool v2');
    final third = await builder.yamlCache(sdk, root, tool.path);
    expect(third, isNot(second));
    expect(commands.generators, 6);
    await File(p.join(third, 'protocol_interface-3.47.2.yaml'))
        .writeAsString('corrupted');
    expect(await builder.yamlCache(sdk, root, tool.path), third);
    expect(commands.generators, 8);
    expect(await builder.yamlCache(sdk, root, tool.path, requireIndex: true),
        third);
    expect(commands.generators, 8);
    await File(p.join(third, 'probe/linked.dill'))
        .writeAsString('corrupted-index');
    expect(await builder.yamlCache(sdk, root, tool.path, requireIndex: true),
        third);
    expect(commands.generators, 10);
  });
}
