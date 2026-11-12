import 'dart:convert';
import 'dart:io';

import 'package:flutter_patcher/src/cli/build/defines.dart';
import 'package:flutter_patcher/src/cli/core.dart';
import 'package:flutter_patcher/src/cli/patch/sources.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

const _code = 'BUILD_CONFIG_INVALID';

Matcher _fails(String code, [String? naming]) => throwsA(
  isA<Failure>()
      .having((f) => f.code, 'code', code)
      .having((f) => f.message, 'message', contains(naming ?? '')),
);

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('defines'));
  tearDown(() => dir.deleteSync(recursive: true));

  String file(String name, String text) {
    final path = p.join(dir.path, name);
    File(path)
      ..createSync(recursive: true)
      ..writeAsStringSync(text);
    return path;
  }

  group('readDefines', () {
    test('merges files in order, then defines, later ones winning', () async {
      final first = file('a.json', '{"A": "file", "B": 3, "C": true}');
      final second = file('b.json', '{"B": "second", "D": 1.5}');
      expect(
        await readDefines([first, second], ['A=cli', 'E=x=y', 'F='], _code),
        {
          'A': 'cli',
          'B': 'second',
          'C': 'true',
          'D': '1.5',
          'E': 'x=y',
          'F': '',
        },
      );
    });

    test('reads a .env file as flutter_tools does', () async {
      final env = file(
        'prod.env',
        '# comment\n'
            'PLAIN=value # trailing\n'
            'DOUBLE="foo#bar=baz"\n'
            "SINGLE='a b'\n"
            'BACK=`c d`\n'
            'EMPTY=\n'
            '\n'
            '  SPACED = x\r\n',
      );
      expect(await readDefines([env], const [], _code), {
        'PLAIN': 'value',
        'DOUBLE': 'foo#bar=baz',
        'SINGLE': 'a b',
        'BACK': 'c d',
        'EMPTY': '',
        'SPACED': 'x',
      });
    });

    test('rejects what it cannot take, naming keys and never values', () {
      expect(
        readDefines([p.join(dir.path, 'none.json')], [], _code),
        _fails(_code),
      );
      expect(
        readDefines([file('bad.json', '{"A": ')], [], _code),
        _fails(_code),
      );
      expect(
        readDefines([file('o.json', '{"A": {"k": "secret"}}')], [], _code),
        _fails(_code, 'A in'),
      );
      expect(
        readDefines([file('n.json', '{"A": null}')], [], _code),
        _fails(_code, 'A in'),
      );
      expect(
        readDefines([file('m.env', 'A="""multi\n')], [], _code),
        _fails(_code),
      );
      expect(readDefines([], ['NOVALUE'], _code), _fails(_code, 'NOVALUE'));
      expect(readDefines([], ['=secret'], _code), _fails(_code));
      expect(
        readDefines([], ['KEY=secret', 'NOVALUE'], _code),
        throwsA(
          isA<Failure>().having(
            (f) => f.message,
            'message',
            isNot(contains('secret')),
          ),
        ),
      );
    });

    test('rejects the defines flutter_tools sets itself', () {
      for (final key in [
        'FLUTTER_APP_FLAVOR',
        'FLUTTER_BUILD_NAME',
        'FLUTTER_BUILD_NUMBER',
        'FLUTTER_VERSION',
        'FLUTTER_CHANNEL',
        'FLUTTER_GIT_URL',
        'FLUTTER_FRAMEWORK_REVISION',
        'FLUTTER_ENGINE_REVISION',
        'FLUTTER_DART_VERSION',
        'FLUTTER_ENABLED_FEATURE_FLAGS',
        'FLUTTER_VERSION_SUFFIX',
        'dart.vm.product',
      ]) {
        expect(readDefines([], ['$key=x'], _code), _fails(_code, key));
        expect(
          readDefines(
            [
              file('$key.json', jsonEncode({key: 'x'})),
            ],
            [],
            _code,
          ),
          _fails(_code, key),
        );
      }
      expect(
        readDefines([], ['A=1'], 'PATCH_CONFIG_INVALID'),
        completion({'A': '1'}),
      );
    });
  });

  group('checkFlutterArgs', () {
    test('passes on the options that reach only the native build', () {
      const args = [
        '-Pkey=value',
        '-P',
        'other=value',
        '--android-project-arg=a=b',
        '--android-project-cache-dir',
        'cache',
        '--no-android-gradle-daemon',
        '--android-skip-build-dependency-validation',
        '--ignore-deprecation',
        '--fatal-warnings',
        '--performance-measurement-file=perf.json',
        '-v',
      ];
      expect(checkFlutterArgs(args, _code, platform: 'android'), args);
      expect(checkFlutterArgs(const [], _code, platform: 'android'), isEmpty);
    });

    test('passes on for iOS only what flutter build ipa has', () {
      const args = [
        '--fatal-warnings',
        '--performance-measurement-file=perf.json',
        '-v',
      ];
      expect(checkFlutterArgs(args, _code, platform: 'ios'), args);
      for (final arg in [
        '-Pkey=value',
        '--android-project-arg=a=b',
        '--no-android-gradle-daemon',
        '--ignore-deprecation',
      ]) {
        expect(
          () => checkFlutterArgs([arg], _code, platform: 'ios'),
          _fails(_code, 'Android build option'),
          reason: arg,
        );
      }
    });

    test('rejects every other option, and says what to use', () {
      for (final arg in [
        '--debug',
        '--profile',
        '--release',
        '--target-platform=android-arm',
        '--split-per-abi',
        '--no-pub',
        '--obfuscate',
        '--split-debug-info=symbols',
        '--no-tree-shake-icons',
        '--enable-experiment=x',
        '--track-widget-creation',
        '--extra-front-end-options=--x',
        '--extra-gen-snapshot-options=--x',
        '--analyze-size',
        '--config-only',
        '--no-codesign',
        '--export-options-plist=x.plist',
        '--local-engine=x',
        'stray',
      ]) {
        expect(
          () => checkFlutterArgs([arg], _code, platform: 'android'),
          _fails(_code),
          reason: arg,
        );
      }
      expect(
        () =>
            checkFlutterArgs(['--flavor', 'paid'], _code, platform: 'android'),
        _fails(_code, 'use --flavor before --'),
      );
      expect(
        () =>
            checkFlutterArgs(['--build-number=7'], _code, platform: 'android'),
        _fails(_code, '--version-code'),
      );
      expect(
        () => checkFlutterArgs(
          ['--dart-define=A=secret'],
          _code,
          platform: 'android',
        ),
        throwsA(
          isA<Failure>().having(
            (f) => f.message,
            'message',
            allOf(
              contains('--dart-define before --'),
              isNot(contains('secret')),
            ),
          ),
        ),
      );
      expect(
        () => checkFlutterArgs(['-P'], _code, platform: 'android'),
        _fails(_code, 'value'),
      );
      expect(
        () => checkFlutterArgs(
          ['--ignore-deprecation=true'],
          _code,
          platform: 'android',
        ),
        _fails(_code, 'no value'),
      );
    });
  });

  group('buildName', () {
    Future<String?> of(String pubspec) {
      file('pubspec.yaml', pubspec);
      return buildName(dir.path);
    }

    test(
      'is the pubspec version before +, as flutter_tools reads it',
      () async {
        expect(await of('name: a\nversion: 1.2.3+45\n'), '1.2.3');
        expect(await of('name: a\nversion: 1.2.3\n'), '1.2.3');
        expect(
          await of('name: a\nversion: "1.2.3-beta.1+7"\n'),
          '1.2.3-beta.1',
        );
        expect(await of('name: a\n'), isNull);
        expect(await of('name: a\nversion: 1.2\n'), isNull);
      },
    );
  });

  const sdk = {
    'FLUTTER_VERSION': '3.47.9',
    'FLUTTER_CHANNEL': '[user-branch]',
    'FLUTTER_GIT_URL': 'https://github.com/flutter/flutter.git',
    'FLUTTER_FRAMEWORK_REVISION': 'c197ca5199',
    'FLUTTER_ENGINE_REVISION': '89c39edfdf',
    'FLUTTER_DART_VERSION': '3.13.7',
  };

  test('sdkDefines reads what flutter_tools defines from the SDK', () async {
    file(
      'sdk/bin/cache/flutter.version.json',
      jsonEncode({
        'frameworkVersion': '3.47.9',
        'channel': '[user-branch]',
        'repositoryUrl': 'https://github.com/flutter/flutter.git',
        'frameworkRevision': 'c197ca5199e9ee5661e865596c9c07294dfab51c',
        'engineRevision': '89c39edfdfae2949f6806e4a315c0c08522238b7',
        'dartSdkVersion': '3.13.7',
      }),
    );
    expect(await sdkDefines(p.join(dir.path, 'sdk')), sdk);
    expect(sdkDefines(dir.path), _fails('SDK_NOT_READY'));
  });

  group('BuildInputs', () {
    BuildInputs host({
      String? flavor = 'paid',
      String? name = '1.2.3',
      Map<String, String> defines = const {'API': 'prod', 'MODE': 'a b&c'},
    }) => BuildInputs.of(
      target: 'lib/main_paid.dart',
      defines: defines,
      flutterArgs: const ['-Pk=v'],
      sdk: sdk,
      flavor: flavor,
      buildName: name,
      buildNumber: '45',
    );

    test('gives its own kernels every define flutter build has', () {
      expect(host().compileDefines, {
        'dart.vm.profile': 'false',
        'dart.vm.product': 'true',
        'FLUTTER_APP_FLAVOR': 'paid',
        'FLUTTER_BUILD_NAME': '1.2.3',
        'FLUTTER_BUILD_NUMBER': '45',
        ...sdk,
        'API': 'prod',
        'MODE': 'a b&c',
      });
      final plain = host(flavor: null, name: null, defines: const {});
      expect(plain.builtins.keys, isNot(contains('FLUTTER_APP_FLAVOR')));
      expect(plain.builtins.keys, isNot(contains('FLUTTER_BUILD_NAME')));
      expect(
        host(flavor: 'default').builtins.keys,
        isNot(contains('FLUTTER_APP_FLAVOR')),
      );
    });

    test('gives flutter build the same inputs', () async {
      final inputs = host();
      final options = await inputs.flutterOptions(dir.path);
      final defines = p.join(
        dir.path,
        '.dart_tool',
        'flutter_patcher_defines.json',
      );
      expect(options, [
        '--build-number',
        '45',
        '--build-name',
        '1.2.3',
        '--dart-define-from-file=$defines',
        '-Pk=v',
      ]);
      expect(jsonDecode(File(defines).readAsStringSync()), inputs.defines);
      expect(await inputs.flutterOptions(dir.path, bundle: true), [
        '--build-number',
        '45',
        '--dart-define-from-file=$defines',
      ]);
      expect(inputs.flutterEnvironment, {
        'FLUTTER_WINDOWING': 'false',
        'FLUTTER_ACCESSIBILITY_EVALUATIONS': 'false',
      });
      expect(
        await host(defines: const {}, name: null).flutterOptions(dir.path),
        ['--build-number', '45', '-Pk=v'],
      );
    });

    test('is recorded and read back', () {
      final receipt = jsonDecode(
        jsonEncode({'build_inputs': host().toJson()}),
      ) as Map<String, dynamic>;
      final read = BuildInputs.read(
        receipt,
        flavor: 'paid',
        target: 'lib/x.dart',
      );
      expect(read.toJson(), host().toJson());
      expect(read.recorded, isTrue);
      expect(
        () => BuildInputs.read(
          {
            'build_inputs': {...host().toJson(), 'schema': 2},
          },
          flavor: 'paid',
          target: 'lib/x.dart',
        ),
        _fails('PATCH_BASELINE_INCOMPATIBLE'),
      );
    });

    test(
      'a host built before 1.1.1 keeps the defines it was built with',
      () async {
        final old = BuildInputs.read(
          const {},
          flavor: 'paid',
          target: 'lib/x.dart',
        );
        expect(old.recorded, isFalse);
        expect(old.target, 'lib/x.dart');
        expect(old.compileDefines, releaseDefines('paid'));
        expect(
          BuildInputs.read(
            const {},
            flavor: 'default',
            target: 'lib/main.dart',
          ).compileDefines,
          releaseDefines(null),
        );
        expect(await old.flutterOptions(dir.path), isEmpty);
        expect(old.flutterEnvironment, isEmpty);
        file('pubspec.yaml', 'name: a\nversion: 9.9.9+1\n');
        final patch = await old.patched(
          project: dir.path,
          sdk: const {},
          overrides: const {'API': 'next'},
          target: 'lib/other.dart',
        );
        expect(patch.inputs.target, 'lib/other.dart');
        expect(patch.inputs.compileDefines, {
          ...releaseDefines('paid'),
          'API': 'next',
        });
        expect(patch.report, {
          'changed': <String>[],
          'added': ['API'],
        });
      },
    );

    group('patched', () {
      setUp(() => file('pubspec.yaml', 'name: a\nversion: 2.0.0+46\n'));

      test('keeps the host\'s inputs when the patch gives none', () async {
        final patch = await host().patched(
          project: dir.path,
          sdk: sdk,
          overrides: const {},
        );
        // Not the project's pubspec, which has moved on to the next version.
        expect(patch.inputs.toJson(), host().toJson());
        expect(patch.report, isNull);
      });

      test('changes and adds the defines the patch gives', () async {
        final patch = await host().patched(
          project: dir.path,
          sdk: sdk,
          overrides: const {'API': 'next', 'MODE': 'a b&c', 'NEW': '1'},
          target: 'lib/main_paid.dart',
        );
        expect(patch.inputs.defines, {
          'API': 'next',
          'MODE': 'a b&c',
          'NEW': '1',
        });
        expect(patch.inputs.builtins, host().builtins);
        expect(patch.inputs.flutterArgs, ['-Pk=v']);
        expect(patch.report, {
          'changed': ['API'],
          'added': ['NEW'],
        });
      });

      test('rejects another entry, SDK or a version the host had not', () {
        const code = 'PATCH_BUILD_INPUTS_MISMATCH';
        expect(
          host().patched(
            project: dir.path,
            sdk: sdk,
            overrides: const {},
            target: 'lib/main.dart',
          ),
          _fails(code, 'lib/main_paid.dart'),
        );
        expect(
          host().patched(
            project: dir.path,
            sdk: {...sdk, 'FLUTTER_CHANNEL': 'stable'},
            overrides: const {},
          ),
          _fails(code, 'FLUTTER_CHANNEL'),
        );
        expect(
          host(name: null)
              .patched(project: dir.path, sdk: sdk, overrides: const {}),
          _fails(code, 'pubspec.yaml'),
        );
      });
    });
  });

  test('defineReaders finds the libraries that read a define', () async {
    file('app/lib/config.dart', '''
const _key = 'API';
const api = String.fromEnvironment(_key);
const on = bool.hasEnvironment("FLAG");
''');
    file('app/lib/other.dart', "const label = 'API';\n");
    file(
      'dep/lib/src/env.dart',
      "const api = String.fromEnvironment('API');\n",
    );
    final config = file(
      'app/.dart_tool/package_config.json',
      jsonEncode({
        'configVersion': 2,
        'packages': [
          {'name': 'app', 'rootUri': '../', 'packageUri': 'lib/'},
          {'name': 'dep', 'rootUri': '../../dep', 'packageUri': 'lib/'},
        ],
      }),
    );
    expect(await defineReaders(config, ['API', 'FLAG', 'TYPO']), {
      'API': ['package:app/config.dart', 'package:dep/src/env.dart'],
      'FLAG': ['package:app/config.dart'],
      'TYPO': <String>[],
    });
    expect(await defineReaders(config, const []), isEmpty);
  });
}
