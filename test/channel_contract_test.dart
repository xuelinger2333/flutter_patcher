import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Android and iOS must expose the same channel. This reads each side's
/// source, so it runs on any host without Gradle or Xcode.
void main() {
  final contract =
      jsonDecode(File('test/contract/channel.json').readAsStringSync()) as Map;
  Set<String> listed(String key) =>
      (contract[key] is Map
              ? (contract[key] as Map).keys
              : contract[key] as List)
          .cast<String>()
          .toSet();
  Set<String> scan(Iterable<File> files, String pattern) => {
    for (final file in files)
      for (final match in RegExp(pattern).allMatches(file.readAsStringSync()))
        match.group(1)!,
  };
  List<File> sources(String dir, String suffix) => Directory(dir).existsSync()
      ? Directory(dir)
            .listSync(recursive: true)
            .whereType<File>()
            .where((file) => file.path.endsWith(suffix))
            .toList()
      : [];
  File kotlin(String name) => File(
    'android/src/main/kotlin/com/flutter_patcher/flutter_patcher/$name.kt',
  );

  final methods = listed('methods');
  final dart = sources('lib', '.dart');
  final swift = sources('ios/flutter_patcher/Sources', '.swift');

  test('Dart calls exactly the contract methods', () {
    expect(
      scan(
        dart,
        r"""(?:invoke(?:Map|List)?Method(?:<[^(]*>)?|call)\(\s*'(\w+)'""",
      ),
      methods,
    );
  });

  test('Android handles exactly the contract methods', () {
    expect(scan([kotlin('FlutterPatcherPlugin')], r'"(\w+)" ->'), methods);
    expect(scan([kotlin('BootstrapBridge')], r'"(\w+)" ->'), {
      'bootPayload',
      'backgroundPayload',
      'markBooting',
    });
  });

  test('iOS handles exactly the contract methods', () {
    expect(scan(swift, r'case "(\w+)":'), methods);
  }, skip: swift.isEmpty);

  test('error codes and statuses match on every side', () {
    final kotlinFiles = sources('android/src/main', '.kt');
    expect(
      scan(kotlinFiles, r'(?:\.error|encodeErrorEnvelope)\("(\w+)"'),
      listed('channel_errors'),
    );
    expect(
      scan([kotlin('ApplyResult')], r'const val \w+ = "(\w+)"'),
      listed('apply_errors'),
    );
    expect(
      scan([File('lib/src/patch_info.dart')], r"case '([A-Z0-9_]+)':"),
      listed('apply_errors')..remove('UNKNOWN'),
    );
    expect(
      scan([File('lib/src/boot_diagnostic.dart')], r"case '(\w+)':"),
      listed('boot_statuses')..remove('UNKNOWN'),
    );
    expect(
      listed('boot_statuses').containsAll(
        scan([kotlin('BootDiagnosticStore')], r'const val \w+ = "([A-Z_]+)"'),
      ),
      isTrue,
    );
    if (swift.isNotEmpty) {
      expect(
        scan(swift, r'FlutterError\(code: "(\w+)"'),
        listed('channel_errors'),
      );
      expect(
        listed(
          'boot_statuses',
        ).containsAll(scan(swift, r'static let \w+ = "([A-Z_]+)"')),
        isTrue,
      );
      final version = RegExp(
        r'^version: (\S+)',
        multiLine: true,
      ).firstMatch(File('pubspec.yaml').readAsStringSync())!.group(1);
      expect(scan(swift, r'pluginVersion = "([0-9.]+)"'), {version});
    }
  });
}
