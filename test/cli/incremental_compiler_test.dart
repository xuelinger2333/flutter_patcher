import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:flutter_patcher/src/cli/core.dart';
import 'package:flutter_patcher/src/cli/patch/sources.dart';

import 'host_tools.dart';

/// Real CFE/bytecode coverage when the pinned tools and platform are available.
/// No Android build or device is needed for this compiler contract.
void main() {
  final tools = Platform.environment['FLUTTER_PATCHER_TEST_TOOLS'];
  final platform = Platform.environment['FLUTTER_PATCHER_TEST_PLATFORM'];
  test(
    'compiled patch reuses an unchanged application library',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'incremental-compiler-',
      );
      addTearDown(() => root.delete(recursive: true));
      final config = p.join(root.path, 'package_config.json');
      await writeObject(config, {
        'configVersion': 2,
        'packages': [
          for (final name in ['app', 'dynamic_modules'])
            {
              'name': name,
              'rootUri': Directory(p.join(root.path, name)).uri.toString(),
              'packageUri': 'lib/',
              'languageVersion': '3.13',
            },
        ],
      });
      Future<void> source(String file, String text) async {
        final target = File(p.join(root.path, file));
        await target.parent.create(recursive: true);
        await target.writeAsString(text);
      }

      Future<String> run(List<String> args) async {
        final result = await Process.run(dartVm, [tools!, ...args]);
        expect(
          result.exitCode,
          0,
          reason: '${result.stdout}\n${result.stderr}',
        );
        return result.stdout as String;
      }

      await source(
        'dynamic_modules/lib/host.dart',
        "import 'package:app/main.dart' as app; void main() => app.main();",
      );
      await source(
        'app/lib/main.dart',
        "import 'changed.dart'; import 'stable.dart'; void main() => print(changed() + stable());",
      );
      const originalSource =
          "String changed() => const String.fromEnvironment('FEATURE', defaultValue: 'before');";
      await source('app/lib/changed.dart', originalSource);
      await source('app/lib/stable.dart', "String stable() => 'host';");
      final analysis = p.join(root.path, 'analysis.dill');
      final baseline = p.join(root.path, 'app.dill');
      final iface = p.join(root.path, 'interface.json');
      final compilerInterface = p.join(root.path, 'compiler_interface.json');
      Future<void> compile(
        String output, {
        bool linked = false,
        bool withInterface = false,
      }) async {
        await run([
          'compile-baseline',
          '--platform',
          platform!,
          '--target',
          'flutter',
          '--no-aot',
          '--no-tfa',
          linked ? '--link-platform' : '--no-link-platform',
          '--packages',
          config,
          if (withInterface) ...[
            '--dynamic-interface',
            iface,
            '--dump-detailed-dynamic-interface',
            compilerInterface,
          ],
          '--output',
          output,
          'package:dynamic_modules/host.dart',
        ]);
      }

      await compile(analysis, linked: true);
      await run([
        'extract-surface',
        '--dill',
        analysis,
        '--own',
        'dynamic_modules',
        '--scan',
        'app',
        '--out-iface',
        iface,
        '--out-trim-iface',
        p.join(root.path, 'trim.json'),
      ]);
      final interface = await readObject(iface);
      for (final section in [
        'callable',
        'can-be-used-as-type',
        'can-be-overridden',
        'extendable',
      ]) {
        (interface[section] as List).add({'library': 'dart:core'});
      }
      await writeObject(iface, interface);
      await compile(baseline, withInterface: true);
      final allocated = p.join(root.path, 'allocated.json');
      await writeObject(allocated, {
        'classes': ['dart:core::pragma'],
      });
      await source('app/lib/changed.dart', "String changed() => 'after';");
      final selected = await selectPatchSources(
        config: config,
        packages: {'app'},
        changed: ['package:app/changed.dart'],
        baselineSources: {
          'package:app/main.dart',
          'package:app/changed.dart',
          'package:app/stable.dart',
        },
        entry: 'package:app/main.dart',
      );
      final module = p.join(root.path, 'module');
      final remap = await remapSources(config, module, {'app'}, 9, selected);
      await File(p.join(module, 'app/__patch_entry.dart')).writeAsString(
        patchEntry('patch.9.app', 'main.dart', 9, 'a' * 64, 'lean'),
      );
      final request = p.join(root.path, 'request.json');
      await writeObject(request, {
        'tier': 'lean',
        'target_os': 'android',
        'emit': true,
        'seq': 9,
        'fingerprint': 'a' * 64,
        'entry': 'package:patch.9.app/__patch_entry.dart',
        'packages': remap['packages'],
        'baseline': baseline,
        'platform': platform,
        'interface': iface,
        'compiler_interface': compilerInterface,
        'allocated': allocated,
        'own': ['patch.9.app'],
        'original_own': <String>[],
        'out': p.join(root.path, 'module.bc'),
      });
      final report =
          jsonDecode(await run(['compile-patch', '--request', request])) as Map;
      expect(report['status'], 'compiled', reason: '$report');
      expect(
        report['emitted_libraries'],
        unorderedEquals([
          'package:patch.9.app/__patch_entry.dart',
          'package:patch.9.app/main.dart',
          'package:patch.9.app/changed.dart',
        ]),
      );
      expect(
        File(p.join(root.path, 'module.bc')).lengthSync(),
        greaterThan(120),
      );
      // A define-only patch still emits just the reader and its callers;
      // the replacement tool must actually fold the supplied value into it.
      await source('app/lib/changed.dart', originalSource);
      await File(p.join(module, 'app/changed.dart'))
          .writeAsString(originalSource);
      final readers = await defineReaders(config, ['FEATURE']);
      expect(readers['FEATURE'], ['package:app/changed.dart']);
      final input = await readObject(request);
      await writeObject(request, {
        ...input,
        'environment_defines': {'FEATURE': 'define-value-after'},
      });
      final defined =
          jsonDecode(await run(['compile-patch', '--request', request])) as Map;
      expect(defined['status'], 'compiled', reason: '$defined');
      expect(
        defined['emitted_libraries'],
        unorderedEquals(report['emitted_libraries'] as List),
      );
      expect(
        latin1.decode(await File(p.join(root.path, 'module.bc')).readAsBytes()),
        contains('define-value-after'),
      );
      await writeObject(request, input);
      // Resource-only patches reuse host main; no application library is emitted.
      await File(p.join(module, 'app/__patch_entry.dart'))
          .writeAsString(patchEntry('app', 'main.dart', 9, 'a' * 64, 'lean'));
      final resourceOnly =
          jsonDecode(await run(['compile-patch', '--request', request])) as Map;
      expect(resourceOnly['status'], 'compiled', reason: '$resourceOnly');
      expect(resourceOnly['emitted_libraries'], [
        'package:patch.9.app/__patch_entry.dart',
      ]);
    },
    skip: tools == null || platform == null
        ? 'Set FLUTTER_PATCHER_TEST_TOOLS and FLUTTER_PATCHER_TEST_PLATFORM'
        : false,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
