import 'package:test/test.dart';
import 'package:flutter_patcher/src/cli/core.dart';
import 'package:flutter_patcher/src/cli/patch/pipeline.dart';
import 'package:flutter_patcher/src/cli/patch/resources.dart';
import 'package:flutter_patcher/src/cli/patch/rules.dart';

Matcher rejects(String code) =>
    throwsA(isA<Failure>().having((f) => f.code, 'code', code));

PatchFacts facts([String strategy = 'bytecode']) =>
    PatchFacts(strategy, 'android', 'work');

void main() {
  group('compareInputs', () {
    final previous = {
      'app': {'native_files': {}},
      'dart_only': {'version': '1'},
      'plugin': {
        'native': true,
        'version': '1',
        'native_files': {'android/src/main/A.kt': 'a'}
      },
    };
    test('records pure Dart dependency changes, native ones as facts', () {
      // Test sources, docs and other platforms never reach the Android build.
      final quiet = facts();
      expect(
          compareInputs({
            ...previous,
            'plugin': {
              'native': true,
              'version': '1',
              'native_files': {
                'android/src/main/A.kt': 'a',
                'android/src/test/T.kt': 't',
                'android/README.md': 'd',
                'ios/Classes/P.swift': 's'
              }
            }
          }, previous, 'app', quiet),
          isFalse);
      expect(quiet.changed, isEmpty);
      final dart = facts();
      expect(
          compareInputs({
            ...previous,
            'dart_only': {'version': '2'}
          }, previous, 'app', dart),
          isTrue);
      expect(dart.changed, ['dependency:dart_only']);
      final native = facts('so');
      compareInputs({
        ...previous,
        'plugin': {'native': true, 'version': '2'}
      }, previous, 'app', native);
      expect(native.nativeDependencies, ['plugin']);
      expect(() => PatchRules().check(PatchStage.inputs, native),
          rejects('PATCH_NATIVE_CHANGE'));
    });
    test('iOS patches compare only what reaches the iOS build', () {
      Map<String, dynamic> app(Map<String, String> files) => {
            'app': {'native': false, 'version': '1', 'native_files': files}
          };
      final before = app({
        'ios/Runner/AppDelegate.swift': 'a',
        'ios/Flutter/Generated.xcconfig': 'path-1',
        'android/app/build.gradle': 'g'
      });
      // Paths Flutter regenerates, per-user Xcode state and Android files.
      final same = facts();
      compareInputs(
          app({
            'ios/Runner/AppDelegate.swift': 'a',
            'ios/Flutter/Generated.xcconfig': 'path-2',
            'ios/Runner.xcworkspace/xcuserdata/u.xcuserdatad/UI.xcuserstate':
                'x',
            'android/app/build.gradle': 'changed'
          }),
          before,
          'app',
          same,
          platform: 'ios');
      expect(same.appNativeChanged, isFalse);
      final changed = facts();
      compareInputs(
          app({
            'ios/Runner/AppDelegate.swift': 'b',
            'ios/Flutter/Generated.xcconfig': 'path-1',
            'android/app/build.gradle': 'g'
          }),
          before,
          'app',
          changed,
          platform: 'ios');
      expect(changed.appNativeChanged, isTrue);
    });
  });

  group('rules', () {
    test('a patch that would run FFI in the interpreter is rejected', () {
      final f = facts()
        ..report = {
          'checks': {'ffi': []}
        };
      PatchRules().check(PatchStage.compile, f);
      f.report = {'checks': <String, dynamic>{}}; // tools without the check
      PatchRules().check(PatchStage.compile, f);
      f.report = {
        'checks': {
          'ffi': [
            {'message': 'FFI call asFunction', 'file': 'main.dart', 'line': 3}
          ]
        }
      };
      expect(() => PatchRules().check(PatchStage.compile, f),
          rejects('PATCH_FFI_UNSUPPORTED'));
      // A rebuilt libapp.so runs FFI natively.
      final so = facts('so')..report = f.report;
      PatchRules().check(PatchStage.compile, so);
    });
    test('native changes reject before pinned packages', () {
      final f = facts()
        ..changedPlugins.add('camera')
        ..changedPinned['http'] =
            (why: 'reached via a -> http', version: '1.0.0');
      expect(() => PatchRules().check(PatchStage.inputs, f),
          rejects('PATCH_NATIVE_CHANGE'));
      f.changedPlugins.clear();
      expect(
          () => PatchRules().check(PatchStage.inputs, f),
          throwsA(isA<Failure>()
              .having((e) => e.message, 'message', contains('  http: 1.0.0'))));
      expect(
          () => PatchRules().check(PatchStage.inputs,
              facts('so')..changedPinned.addAll(f.changedPinned)),
          returnsNormally);
    });
    test('both strategies need the engine asset channel for assets', () {
      for (final strategy in ['bytecode', 'so']) {
        final f = facts(strategy)..assets = ['a'];
        expect(() => PatchRules().check(PatchStage.resources, f),
            rejects('PATCH_ENGINE_UNSUPPORTED'));
        f.enginePatches = [engineAssetChannelPatch];
        PatchRules().check(PatchStage.resources, f);
        f.deletedAssets = ['b'];
        expect(() => PatchRules().check(PatchStage.resources, f),
            rejects('PATCH_ASSET_DELETE_UNSUPPORTED'));
      }
    });
    test('the final verdicts of a bytecode module', () {
      final f = facts()
        ..tier = 'whole'
        ..report = {'status': 'rejected'};
      expect(() => PatchRules().check(PatchStage.code, f),
          rejects('PATCH_UNSAFE'));
      f.report = {
        'status': 'compiled',
        'dynamic_fonts': [{}]
      };
      expect(() => PatchRules().check(PatchStage.code, f),
          rejects('PATCH_DYNAMIC_ICON'));
      expect(() => PatchRules().check(PatchStage.result, facts('so')),
          rejects('PATCH_NO_CHANGES'));
    });
    test('warnings accumulate instead of rejecting', () {
      final rules = PatchRules([
        PatchRule('W', PatchStage.result, (f) => ['one', 'two'], reject: false)
      ]);
      rules.check(PatchStage.result, facts());
      expect(rules.warnings.map((w) => w['message']), ['one', 'two']);
      expect(PatchRules.describe().map((r) => r['code']),
          containsAll(['PATCH_NATIVE_CHANGE', 'PATCH_NO_CHANGES']));
    });
  });
}
