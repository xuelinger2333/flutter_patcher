import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:flutter_patcher_cli/src/build/virtual_paths.dart';

void main() {
  late Directory temp;
  late String cache, work;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('wp26-virtual-');
    cache = p.join(temp.path, 'cache');
    work = p.join(cache, 'builds', 'run.pending-1-2');
    await Directory(p.join(work, 'project', '.dart_tool'))
        .create(recursive: true);
  });
  tearDown(() => temp.delete(recursive: true));

  Future<Map<String, String>> rewrite(List<Map<String, String>> rows) async {
    final config = p.join(work, 'project', '.dart_tool', 'package_config.json');
    await File(config)
        .writeAsString(jsonEncode({'configVersion': 2, 'packages': rows}));
    final virtual = await VirtualPackages.write(config, [work, cache]);
    expect(virtual.packagesUri,
        'org-dartlang-root:///package_config.virtual.json');
    expect(virtual.compilerArgs, [
      '--filesystem-scheme',
      'org-dartlang-root',
      '--filesystem-root',
      work,
      '--filesystem-root',
      cache
    ]);
    final written = jsonDecode(
        await File(p.join(work, 'package_config.virtual.json'))
            .readAsString()) as Map;
    return {
      for (final row in written['packages'] as List)
        row['name'] as String: row['rootUri'] as String
    };
  }

  test('work and cache roots become host-independent URIs', () async {
    final roots = await rewrite([
      {'name': 'app', 'rootUri': '../', 'packageUri': 'lib/'},
      {
        'name': 'dep',
        'rootUri': p.toUri(p.join(work, 'dependencies', '0')).toString()
      },
      {
        'name': 'archive',
        'rootUri': p
            .toUri(p.join(cache, 'pub-cache', 'hosted', 'pub.dev', 'a b-1.0'))
            .toString()
      },
      {
        'name': 'flutter',
        'rootUri': p
            .toUri(p.join(cache, 'flutter', '3.47.2', 'packages', 'flutter'))
            .toString()
      },
    ]);
    expect(roots, {
      'app': 'org-dartlang-root:///project/',
      'dep': 'org-dartlang-root:///dependencies/0/',
      'archive': 'org-dartlang-root:///pub-cache/hosted/pub.dev/a%20b-1.0/',
      'flutter': 'org-dartlang-root:///flutter/3.47.2/packages/flutter/',
    });
  });

  test('outside or shadowed roots keep their file URI', () async {
    final outside = p.toUri(p.join(temp.path, 'elsewhere')).toString();
    await Directory(p.join(work, 'pub-cache')).create();
    final shadowed =
        p.toUri(p.join(cache, 'pub-cache', 'hosted', 'x')).toString();
    final roots = await rewrite([
      {'name': 'outside', 'rootUri': outside},
      {'name': 'shadowed', 'rootUri': shadowed},
    ]);
    expect(roots, {'outside': outside, 'shadowed': shadowed});
  });
}
