import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:flutter_patcher/src/cli/core.dart';
import 'package:flutter_patcher/src/cli/build/defines.dart';
import 'package:flutter_patcher/src/cli/build/host_policy.dart';
import 'package:flutter_patcher/src/cli/build/ios.dart';
import 'package:flutter_patcher/src/cli/build/pipeline.dart';
import 'package:flutter_patcher/src/cli/patch/resources.dart';

import 'baseline_test.dart' as base;

void main() {
  late Directory temp;
  setUp(() async => temp = await Directory.systemTemp.createTemp('ios-build-'));
  tearDown(() => temp.delete(recursive: true));

  HostPolicy policy(String abi) => HostPolicy({
    'schema': '2',
    'application_id': 'com.example.app',
    'version_code': '42',
    'channel': 'stable',
    'flavor': 'default',
    'abi': abi,
    'strategy': 'bytecode',
    'fptc_key': base.testPublicKey,
  });

  test(
    'the policy ABI selects the platform; export method is iOS only',
    () async {
      await File(p.join(temp.path, 'lib/main.dart')).create(recursive: true);
      BuildRequest request(String abi, String? method) => BuildRequest(
        project: temp.path,
        output: p.join(temp.path, 'out-$abi'),
        publicKey: base.testPublicKey,
        hostPolicy: policy(abi),
        exportMethod: method,
      );
      expect(request('ios-arm64', null).platform, 'ios');
      await request('ios-arm64', 'development').validate();
      await expectLater(
        request('arm64-v8a', 'development').validate(),
        throwsA(
          isA<Failure>().having((f) => f.code, 'code', 'BUILD_CONFIG_INVALID'),
        ),
      );
    },
  );

  test('flutter build ipa gets the inputs the host records', () async {
    final project = temp;
    late List<String> args;
    late Map<String, String>? environment;
    Future<String> run(
      String executable,
      List<String> given, {
      String? cwd,
      Map<String, String>? env,
    }) async {
      args = given;
      environment = env;
      await File(p.join(project.path, 'build/ios/ipa/app.ipa'))
          .create(recursive: true);
      return '';
    }

    final request = BuildRequest(
      project: project.path,
      output: p.join(project.path, 'out'),
      publicKey: base.testPublicKey,
      hostPolicy: policy('ios-arm64'),
      flavor: 'paid',
      versionCode: '45',
      exportMethod: 'ad-hoc',
    );
    final inputs = BuildInputs.of(
      target: 'lib/main_paid.dart',
      defines: const {'API': 'a b&c'},
      flutterArgs: const [],
      sdk: const {'FLUTTER_VERSION': '3.47.9'},
      flavor: 'paid',
      buildName: '1.2.3',
      buildNumber: '45',
    );
    await assembleIpa(
      run,
      'flutter',
      project.path,
      request,
      inputs.target,
      const ['--no-codesign'],
      inputs,
    );
    final defines = p.join(
      project.path,
      '.dart_tool',
      'flutter_patcher_defines.json',
    );
    expect(args, [
      '--suppress-analytics',
      'build',
      'ipa',
      '--release',
      '--target',
      'lib/main_paid.dart',
      '--flavor',
      'paid',
      '--build-number',
      '45',
      '--build-name',
      '1.2.3',
      '--dart-define-from-file=$defines',
      '--export-method',
      'ad-hoc',
      '--no-codesign',
    ]);
    expect(jsonDecode(File(defines).readAsStringSync()), {'API': 'a b&c'});
    expect(environment, inputs.flutterEnvironment);

    // A host built before its inputs were recorded: as it was built then.
    await assembleIpa(
      run,
      'flutter',
      project.path,
      request,
      'lib/main.dart',
      const [],
      BuildInputs.read(const {}, flavor: 'paid', target: 'lib/main.dart'),
    );
    expect(args.sublist(4), [
      '--target',
      'lib/main.dart',
      '--flavor',
      'paid',
      '--build-number',
      '45',
      '--export-method',
      'ad-hoc',
    ]);
  });

  test('LC_UUID identifies a re-signed engine', () {
    final header = ByteData(32 + 16 + 24);
    for (final (i, b) in [207, 250, 237, 254, 12, 0, 0, 1].indexed) {
      header.setUint8(i, b);
    }
    header
      ..setUint32(16, 2, Endian.little)
      ..setUint32(32, 0x19, Endian.little)
      ..setUint32(36, 16, Endian.little)
      ..setUint32(48, 0x1b, Endian.little)
      ..setUint32(52, 24, Endian.little);
    final bytes = header.buffer.asUint8List().toList()
      ..setRange(56, 72, List.generate(16, (i) => i + 1));
    expect(machoUuid(bytes), List.generate(16, (i) => i + 1));
    expect(machoUuid([127, 69, 76, 70, ...bytes.skip(4)]), isNull);
    // App.framework is a universal binary with one arm64 slice.
    final fat = ByteData(32)
      ..setUint32(0, 0xcafebabe)
      ..setUint32(4, 1)
      ..setUint32(8, 0x0100000c)
      ..setUint32(16, 32)
      ..setUint32(20, bytes.length);
    expect(
      machoUuid([...fat.buffer.asUint8List(), ...bytes]),
      List.generate(16, (i) => i + 1),
    );
  });

  test('NOTICES.Z is identified by its text, not the gzip OS byte', () {
    Map receipt(int os) {
      final bytes = gzip.encode(utf8.encode('licenses'))..[9] = os;
      return resourceReceipt(
        Archive()..addFile(
          ArchiveFile('assets/flutter_assets/NOTICES.Z', bytes.length, bytes),
        ),
      );
    }

    expect(receipt(0x0a)['files'], receipt(0x03)['files']);
  });

  test('iOS flutter_assets give the same resource receipt as an APK', () async {
    await File(p.join(temp.path, 'fonts/a.ttf'))
        .create(recursive: true)
        .then((f) => f.writeAsBytes([1, 2, 3]));
    final receipt = resourceReceipt(await flutterAssetsArchive(temp.path));
    expect((receipt['files'] as Map).keys, ['fonts/a.ttf']);
  });
}
