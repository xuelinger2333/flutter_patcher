import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:flutter_patcher/src/cli/baseline/repository.dart';
import 'package:flutter_patcher/src/cli/build/defines.dart';
import 'package:flutter_patcher/src/cli/core.dart';
import 'package:flutter_patcher/src/cli/patch/bytecode.dart';
import 'package:flutter_patcher/src/cli/patch/pipeline.dart';
import 'package:flutter_patcher/src/cli/patch/rules.dart';
import 'package:flutter_patcher/src/cli/sdk/artifacts.dart';

import 'host_tools.dart';

/// Keep asset bundling out of this compiler test; all module compiles and
/// safety checks use the real tools and released host Kernel.
class _Commands extends Commands {
  _Commands(super.cache);
  bool omitLocations = false, fileLocations = false;

  @override
  Future<CommandResult> runResult(
    String executable,
    List<String> args, {
    String? cwd,
    List<int>? inputBytes,
    String code = 'TOOL_FAILED',
    Duration timeout = const Duration(minutes: 15),
    Map<String, String>? extraEnvironment,
    String? logPath,
  }) async {
    if (args.contains('bundle')) return CommandResult(0, '', '');
    final result = await super.runResult(
      executable,
      args,
      cwd: cwd,
      inputBytes: inputBytes,
      code: code,
      timeout: timeout,
      extraEnvironment: extraEnvironment,
      logPath: logPath,
    );
    if (omitLocations &&
        args.contains('compile-patch') &&
        result.exitCode == 0) {
      final report = jsonDecode(result.stdout) as Map;
      for (final row
          in (report['checks'] as Map?)?['interface'] as List? ?? const []) {
        (row as Map)['file'] = null;
      }
      return CommandResult(result.exitCode, jsonEncode(report), result.stderr);
    }
    if (fileLocations && args.contains('--help')) {
      return CommandResult(
        result.exitCode,
        result.stdout.replaceAll('filesystem_roots', ''),
        result.stderr,
      );
    }
    return result;
  }
}

void main() {
  final tools = Platform.environment['FLUTTER_PATCHER_TEST_TOOLS'];
  final platform = Platform.environment['FLUTTER_PATCHER_TEST_PLATFORM'];
  group(
    'selective patches against a released interface',
    () {
      late Directory root;
      late String config, baseline, sdkRoot, originalChanged;
      late ResolvedRelease release;
      var sequence = 0;

      Future<void> source(String file, String text) async {
        final target = File(p.join(root.path, file));
        await target.parent.create(recursive: true);
        await target.writeAsString(text);
      }

      Future<void> tool(List<String> args) async {
        final result = await Process.run(dartVm, [tools!, ...args]);
        expect(
          result.exitCode,
          0,
          reason: '${result.stdout}\n${result.stderr}',
        );
      }

      setUpAll(() async {
        root = await Directory.systemTemp.createTemp('incremental-retry-');
        sdkRoot = p.normalize(p.join(p.dirname(dartVm), '../../../..'));
        config = p.join(root.path, 'package_config.json');
        baseline = p.join(root.path, 'baseline');
        await writeObject(config, {
          'configVersion': 2,
          'packages': [
            for (final name in ['app', 'dep', 'host_api', 'dynamic_modules'])
              {
                'name': name,
                'rootUri': Directory(p.join(root.path, name)).uri.toString(),
                'packageUri': 'lib/',
                'languageVersion': '3.13',
              },
          ],
        });
        await source(
          'app/pubspec.yaml',
          'name: app\ndependencies:\n  dep: any\n  host_api: any\n',
        );
        await source('dep/pubspec.yaml', 'name: dep\n');
        await source(
          'host_api/pubspec.yaml',
          'name: host_api\nflutter:\n  plugin:\n    platforms: {}\n',
        );
        final sources = {
          'dynamic_modules/host.dart': "import 'package:app/main.dart' as app; void main() => app.main();",
          'app/main.dart': "import 'changed.dart'; import 'stable.dart'; void main() => print(changed() + stable);",
          'app/changed.dart': "import 'helpers.dart'; import 'chain0.dart' as chain; import 'package:dep/api.dart' as dep; import 'package:host_api/api.dart' as host; String changed() => helperUsed() + chain.used() + dep.used() + host.used();",
          'app/stable.dart': "const stable = 'stable';",
          'app/helpers.dart': "String helperUsed() => 'used'; String parseTags() => 'tags'; String get tagValue => 'getter'; class Tags { Tags(); }",
          'dep/api.dart':
              "String used() => 'used'; String firstUse() => 'dependency';",
          'host_api/api.dart':
              "String used() => 'used'; String firstUse() => 'pinned';",
          for (var i = 0; i < 5; i++)
            'app/chain$i.dart': i == 4
                ? "String used() => 'used'; String firstUse() => 'chain';"
                : "import 'chain${i + 1}.dart' as next; String used() => next.used(); String firstUse() => next.firstUse();",
        };
        originalChanged = sources['app/changed.dart']!;
        for (final entry in sources.entries) {
          final uri = Uri.parse('package:${entry.key}');
          await source(
            '${uri.pathSegments.first}/lib/${uri.pathSegments.skip(1).join('/')}',
            entry.value,
          );
        }
        await source('app/lib/unused.dart', 'void neverReached() {}');
        await source('dep/lib/unused.dart', 'void neverReached() {}');
        await Directory(baseline).create();
        final iface = p.join(baseline, 'dynamic_interface.yaml');
        Future<void> host(String output, {bool analysis = false}) => tool([
          'compile-baseline',
          '--platform',
          platform!,
          '--target',
          'flutter',
          '--no-aot',
          '--no-tfa',
          analysis ? '--link-platform' : '--no-link-platform',
          '--packages',
          config,
          if (!analysis) ...[
            '--dynamic-interface',
            iface,
            '--dump-detailed-dynamic-interface',
            p.join(baseline, 'compiler_interface.json'),
          ],
          '--output',
          output,
          'package:dynamic_modules/host.dart',
        ]);
        final analysis = p.join(root.path, 'analysis.dill');
        await host(analysis, analysis: true);
        // This is upstream's extraction scope: app-internal references do
        // not become retained host entries merely to make selection work.
        await tool([
          'extract-surface',
          '--dill',
          analysis,
          '--own',
          'app',
          '--scan',
          'dep',
          '--out-iface',
          iface,
          '--out-trim-iface',
          p.join(root.path, 'trim.yaml'),
        ]);
        final interface = await readObject(iface);
        expect(
          (interface['callable'] as List).where(
            (r) => (r as Map)['library'].toString().startsWith('package:app/'),
          ),
          isEmpty,
        );
        // The real build adds protocol entries; use only app.main here.
        (interface['callable'] as List).add({
          'library': 'package:app/main.dart',
          'member': 'main',
        });
        for (final section in [
          'callable',
          'can-be-used-as-type',
          'can-be-overridden',
          'extendable',
        ]) {
          (interface[section] as List).add({'library': 'dart:core'});
        }
        await writeObject(iface, interface);
        await host(p.join(baseline, 'app.dill'));
        await writeObject(p.join(baseline, 'allocate_finalized.json'), {
          'classes': ['dart:core::pragma', 'dart:core::Object'],
        });
        final hashes = {
          for (final entry in sources.entries)
            'package:${entry.key}': await hashFile(
              p.join(
                root.path,
                Uri.parse('package:${entry.key}').pathSegments.first,
                'lib',
                Uri.parse('package:${entry.key}').pathSegments
                    .skip(1)
                    .join('/'),
              ),
            ),
        };
        await writeObject(p.join(baseline, 'source_hashes.json'), {
          'files': hashes,
        });
        await writeObject(p.join(baseline, 'compile_receipt.json'), {
          'pinned_packages': {
            'host_api': {'reason': 'plugin'},
          },
        });
        await File(config).copy(p.join(baseline, 'package_config.json'));
        release = ResolvedRelease(
          format: 'legacy',
          flavor: 'default',
          versionCode: '1',
          abi: 'arm64-v8a',
          fingerprint: 'a' * 64,
          compileRoot: baseline,
          releaseRoot: baseline,
          compile: {
            'schema': 3,
            'flutter_version': 'fixture',
            'engine_commit': 'fixture',
            'runtime_bootstrap': true,
            'host_policy_sha256': 'b' * 64,
            'platform': {'path': p.relative(platform!, from: sdkRoot)},
          },
          receipt: {
            'module_identity': 1,
            'package_inputs': {
              'app': {
                'dart_files': {
                  'unused.dart': await hashFile(
                    p.join(root.path, 'app/lib/unused.dart'),
                  ),
                },
              },
            },
          },
        );
      });
      tearDownAll(() => root.delete(recursive: true));

      Future<({BytecodeProducer producer, PatchRun run})> patch(
        String code, {
        bool omitLocations = false,
        bool fileLocations = false,
      }) async {
        await source('app/lib/changed.dart', code);
        final work = p.join(root.path, 'patch-${sequence++}');
        await Directory(work).create();
        final commands = _Commands(root.path)
          ..omitLocations = omitLocations
          ..fileLocations = fileLocations;
        final pipeline = PatchPipeline(
          commands,
          SdkIdentity(sdkRoot, 'fixture', 'fixture', 'fixture', 'fixture'),
          sdkRoot,
          tools!,
          root.path,
          BaselineRepository(p.join(root.path, 'cache'), null),
        );
        final run =
            PatchRun(
                pipeline,
                PatchRequest(
                  project: p.join(root.path, 'app'),
                  output: p.join(work, 'output'),
                  moduleId: 9,
                  minBuild: 1,
                ),
                release,
                work,
              )
              ..project = p.join(root.path, 'app')
              ..config = config
              ..app = 'app'
              ..patch = PatchInputs(
                BuildInputs(
                  target: 'lib/main.dart',
                  defines: const {},
                  builtins: const {},
                ),
                changed: const [],
                added: const [],
              );
        final producer = BytecodeProducer(run);
        await producer.prepare();
        await producer.inputs(false);
        run.rules.check(PatchStage.inputs, run.facts);
        return (producer: producer, run: run);
      }

      test('resource-only compilation still reuses host main', () async {
        final f = await patch(originalChanged);
        final code = await f.producer.produce();
        expect(f.run.facts.report!['status'], 'compiled');
        expect(code.report['selected_sources'], isEmpty);
        expect(f.run.facts.report!['emitted_libraries'], [
          'package:patch.9.app/__patch_entry.dart',
        ]);
      });

      test('file URI diagnostics expand the same sources', () async {
        final f = await patch(
          "import 'helpers.dart'; String changed() => parseTags();",
          fileLocations: true,
        );
        final code = await f.producer.produce();
        expect(f.run.facts.report!['status'], 'compiled');
        expect(f.run.reports.length, 2);
        expect(code.report['selection'], 'libraries');
        expect(
          code.report['selected_sources'],
          contains('package:app/helpers.dart'),
        );
      });

      test(
        'long API chains stop library retries before package fallback',
        () async {
          final f = await patch(
            "import 'chain0.dart'; String changed() => firstUse();",
          );
          final code = await f.producer.produce();
          expect(f.run.facts.report!['status'], 'compiled');
          expect(f.run.reports.length, 5);
          expect(
            f.run.reports.take(4).every((r) => r['selection'] == 'libraries'),
            isTrue,
          );
          expect(code.report['selection'], 'application');
          expect(
            code.report['selected_sources'],
            contains('package:app/chain4.dart'),
          );
        },
      );

      for (final expression in [
        'parseTags()',
        'tagValue',
        'Tags().toString()',
      ]) {
        test('first use of existing app API: $expression', () async {
          final f = await patch(
            "import 'helpers.dart'; String changed() => $expression;",
          );
          final code = await f.producer.produce();
          expect(f.run.reports.first['status'], 'rejected');
          expect(
            f.run.facts.report!['status'],
            'compiled',
            reason: '${f.run.reports}',
          );
          expect(f.run.reports.length, 2);
          expect(code.report['selection'], 'libraries');
          expect(
            code.report['selected_sources'],
            contains('package:app/helpers.dart'),
          );
          expect(
            code.report['selected_sources'],
            isNot(contains('package:app/unused.dart')),
          );
          expect(File(code.file).lengthSync(), greaterThan(120));
        });
      }

      test(
        'first pure-Dart dependency API is carried without a new host',
        () async {
          final f = await patch(
            "import 'package:dep/api.dart'; String changed() => firstUse();",
          );
          final code = await f.producer.produce();
          expect(f.run.reports.first['status'], 'rejected');
          expect(f.run.facts.report!['status'], 'compiled');
          expect(code.metadata['tier'], 'whole');
          expect(code.report['selection'], 'libraries');
          expect(
            code.report['selected_sources'],
            contains('package:dep/api.dart'),
          );
          expect(
            code.report['selected_sources'],
            isNot(contains('package:dep/unused.dart')),
          );
        },
      );

      test(
        'reports without locations fall back to the application package',
        () async {
          final f = await patch(
            "import 'helpers.dart'; String changed() => parseTags();",
            omitLocations: true,
          );
          final code = await f.producer.produce();
          expect(f.run.facts.report!['status'], 'compiled');
          expect(f.run.reports.length, 2);
          expect(code.report['selection'], 'application');
          expect(
            code.report['selected_sources'],
            contains('package:app/unused.dart'),
          );
        },
      );

      test(
        'unresolved locations fall back through application and free packages',
        () async {
          final f = await patch(
            "import 'helpers.dart'; import 'package:dep/api.dart'; String changed() => parseTags() + firstUse();",
            omitLocations: true,
          );
          final code = await f.producer.produce();
          expect(f.run.facts.report!['status'], 'compiled');
          expect(f.run.reports.map((r) => r['selection']), [
            'libraries',
            'application',
            'whole',
          ]);
          expect(
            code.report['selected_sources'],
            contains('package:dep/unused.dart'),
          );
          expect(
            f.run.facts.report!['emitted_libraries'],
            contains('package:patch.9.dep/api.dart'),
          );
          expect(File(code.file).lengthSync(), greaterThan(120));
        },
      );

      test('a missing pinned API remains rejected after bounded fallbacks', () async {
        final f = await patch(
          "import 'package:host_api/api.dart'; String changed() => firstUse();",
        );
        final code = await f.producer.produce();
        expect(f.run.facts.report!['status'], 'rejected');
        expect(f.run.reports.length, lessThanOrEqualTo(6));
        expect(
          (code.report['selected_sources'] as List).where(
            (u) => u.toString().startsWith('package:host_api/'),
          ),
          isEmpty,
        );
        expect(
          () => f.run.rules.check(PatchStage.code, f.run.facts),
          throwsA(isA<Failure>().having((e) => e.code, 'code', 'PATCH_UNSAFE')),
        );
      });

      test('source errors stop without package retries', () async {
        final f = await patch('String changed() => doesNotExist();');
        await expectLater(
          f.producer.produce(),
          throwsA(
            isA<Failure>().having(
              (e) => e.code,
              'code',
              'PATCH_COMPILE_FAILED',
            ),
          ),
        );
        expect(f.run.reports.length, 1);
      });

      test('FFI rejection stops before any fallback', () async {
        final f = await patch(
          "import 'dart:ffi'; String changed() => Pointer<NativeFunction<Int32 Function()>>.fromAddress(1).asFunction<int Function()>()().toString();",
        );
        await expectLater(
          f.producer.produce(),
          throwsA(
            isA<Failure>().having(
              (e) => e.code,
              'code',
              'PATCH_FFI_UNSUPPORTED',
            ),
          ),
        );
        expect(f.run.reports.length, 1);
      });
    },
    skip: tools == null || platform == null
        ? 'Set FLUTTER_PATCHER_TEST_TOOLS and FLUTTER_PATCHER_TEST_PLATFORM'
        : false,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
