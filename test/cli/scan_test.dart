import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:flutter_patcher/src/cli/patch/resources.dart';
import 'package:flutter_patcher/src/cli/patch/rules.dart';
import 'package:flutter_patcher/src/cli/patch/scan.dart';

void main() {
  late Directory temp;
  late SourceScan scan;
  Future<void> file(String path, String text) async {
    final f = File(p.join(temp.path, path));
    await f.parent.create(recursive: true);
    await f.writeAsString(text);
  }

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('scan-');
    const plugin = 'flutter:\n  plugin:\n    platforms: {}\n';
    await file('app/pubspec.yaml', 'name: app\n');
    await file('app/lib/main.dart', '''
import 'package:video/video.dart';
@pragma('vm:entry-point')
void main() {}
const clip = 'assets/intro.mp4';
@pragma('vm:entry-point')
Future<void> callbackDispatcher() async {}
void register() => Workmanager().initialize(callbackDispatcher);
''');
    await file('local/pubspec.yaml', 'name: local\n');
    await file('local/lib/jobs.dart', '''
class Jobs {
  @pragma("vm:entry-point")
  static void onAlarm(int id) {}
}
''');
    // A reader in main sources; only its test reads assets in another plugin.
    await file(
        'cache/hosted/pub.dev/video/pubspec.yaml', 'name: video\n$plugin');
    await file('cache/hosted/pub.dev/video/lib/video.dart', '');
    await file('cache/hosted/pub.dev/video/android/src/main/V.kt',
        'val key = loader.getLookupKeyForAsset(asset)\n');
    await file(
        'cache/hosted/pub.dev/quiet/pubspec.yaml', 'name: quiet\n$plugin');
    await file('cache/hosted/pub.dev/quiet/lib/quiet.dart', '''
@pragma('vm:entry-point')
void notAppCode() {}
''');
    await file('cache/hosted/pub.dev/quiet/android/src/test/T.kt',
        'getLookupKeyForAsset("x")\n');
    await file('cache/hosted/pub.dev/quiet/ios/Classes/Q.swift',
        'registrar.lookupKey(forAsset: "x")\n');
    await file('sdk/packages/flutter/lib/f.dart', '');
    Uri lib(String dir) => Directory(p.join(temp.path, dir, 'lib')).uri;
    scan = SourceScan(
        {
          'app': lib('app'),
          'local': lib('local'),
          'video': lib('cache/hosted/pub.dev/video'),
          'quiet': lib('cache/hosted/pub.dev/quiet'),
          'flutter': lib('sdk/packages/flutter'),
        },
        'app',
        sdkRoots: [p.join(temp.path, 'sdk')]);
  });
  tearDown(() => temp.delete(recursive: true));

  test('own code is the app and its local packages', () {
    expect(scan.own, ['app', 'local']);
  });
  test('native asset readers: main sources of plugins on that platform',
      () async {
    final android = await scan.nativeAssetReaders('android');
    expect(android.keys, ['video']);
    expect(siteText(android['video']!), 'video/android/src/main/V.kt:1');
    expect((await scan.nativeAssetReaders('ios')).keys, isEmpty);
  });
  test('an asset named beside an import of a reader', () async {
    final passed = await scan
        .assetsPassedTo(['video'], ['assets/intro.mp4', 'assets/other.png']);
    expect(passed.keys, ['assets/intro.mp4']);
    expect(siteText(passed['assets/intro.mp4']!.single), 'app/lib/main.dart:4');
  });
  test('background entry points of own code, not main', () async {
    final found = await scan.backgroundEntries();
    expect(found.entries.map((e) => '${e.$1} ${siteText(e.$2)}'), [
      'callbackDispatcher app/lib/main.dart:6',
      'onAlarm local/lib/jobs.dart:3',
    ]);
    expect(found.registrations.map(siteText), ['app/lib/main.dart:7']);
  });

  group('warning rules', () {
    PatchFacts facts(String strategy) =>
        PatchFacts(strategy, 'android', 'work');
    final site = (package: 'app', file: 'lib/main.dart', line: 6);

    test('warn without rejecting, only when they apply', () {
      final rules = PatchRules();
      final f = facts('bytecode')
        ..assets = ['assets/intro.mp4', 'AssetManifest.bin']
        ..engineCapabilities = [assetOverlay]
        ..nativeAssetReaders = {'video': site}
        ..assetsPassed = {
          'assets/intro.mp4': [site]
        }
        ..backgroundEntries = [('callbackDispatcher', site)]
        ..resourceBytes = resourceWarnBytes + 1
        ..largestResources = [('assets/intro.mp4', resourceWarnBytes + 1)];
      rules.check(PatchStage.resources, f);
      expect(rules.warnings.map((w) => w['code']), [
        'PATCH_NATIVE_ASSET_READER',
        'PATCH_NATIVE_ASSET_READER',
        'PATCH_BACKGROUND_ENTRY',
        'PATCH_RESOURCE_SIZE',
      ]);
      expect(rules.warnings[1]['message'], contains('app/lib/main.dart:6'));
      final quiet = PatchRules();
      quiet.check(PatchStage.resources, facts('bytecode'));
      expect(quiet.warnings, isEmpty);
    });
    test('an SO patch only loses assets in a background engine', () {
      final codeOnly = PatchRules();
      codeOnly.check(
          PatchStage.resources,
          facts('so')
            ..changed.add('libapp.so')
            ..backgroundEntries = [('callbackDispatcher', site)]);
      expect(codeOnly.warnings, isEmpty);
      final bytecode = PatchRules();
      bytecode.check(
          PatchStage.resources,
          facts('bytecode')
            ..changed.add('package:app/main.dart')
            ..backgroundEntries = [('callbackDispatcher', site)]);
      expect(bytecode.warnings.single['message'],
          contains("release's code and assets"));
      final assets = PatchRules();
      assets.check(
          PatchStage.resources,
          facts('so')
            ..assets = ['a.png']
            ..engineCapabilities = [assetOverlay]
            ..backgroundEntries = [('callbackDispatcher', site)]);
      expect(assets.warnings.single['message'],
          contains("this patch's code but the release's assets"));
    });
    test('an engine with the entry hook boots background engines too', () {
      const hooked = [assetOverlay, isolateEntry];
      final so = PatchRules();
      so.check(
          PatchStage.resources,
          facts('so')
            ..changed.add('libapp.so')
            ..assets = ['a.png']
            ..engineCapabilities = hooked
            ..backgroundEntries = [('callbackDispatcher', site)]);
      expect(so.warnings, isEmpty);
      PatchFacts bytecode(List<String> entries) => facts('bytecode')
        ..changed.add('package:app/main.dart')
        ..engineCapabilities = hooked
        ..report = {'entries': entries}
        ..backgroundEntries = [
          ('callbackDispatcher', site),
          ('run', (package: 'app', file: 'lib/src/jobs.dart', line: 3)),
        ];
      final carried = PatchRules();
      carried.check(
          PatchStage.resources,
          bytecode([
            'package:app/main.dart#main',
            'package:app/main.dart#callbackDispatcher',
            'package:app/src/jobs.dart#Jobs.run',
          ]));
      expect(carried.warnings, isEmpty);
      // Same name, other library: not this entry point.
      final missed = PatchRules();
      missed.check(PatchStage.resources,
          bytecode(['package:app/other.dart#callbackDispatcher']));
      expect(
          missed.warnings.single['message'],
          allOf(
              contains('does not carry'),
              contains('callbackDispatcher (app/lib/main.dart:6)'),
              contains('run (app/lib/src/jobs.dart:3)')));
    });
  });
}
