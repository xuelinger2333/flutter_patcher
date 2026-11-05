import 'dart:io';

import 'package:flutter_patcher/src/cli/version.dart';
import 'package:test/test.dart';

void main() {
  test(
    'the CLI, the iOS plugin and its podspec report the package version',
    () {
      final pubspec = File('pubspec.yaml').readAsStringSync();
      expect(
        RegExp(r'^version:\s*(\S+)', multiLine: true).firstMatch(pubspec)![1],
        packageVersion,
      );
      // Android reads pubspec.yaml at build time; iOS carries its own copies.
      expect(
        File('ios/flutter_patcher/Sources/flutter_patcher/Bytecode.swift')
            .readAsStringSync(),
        contains('static let pluginVersion = "$pluginVersion"'),
      );
      expect(
        File('ios/flutter_patcher.podspec').readAsStringSync(),
        contains("s.version          = '$pluginVersion'"),
      );
    },
  );

  test('.pubignore leaves out no package source', () {
    // An unanchored `build/` once dropped lib/src/cli/build/ from 1.0.0.
    final names = [
      for (final line in File('.pubignore').readAsLinesSync())
        if (line.trim().isNotEmpty &&
            !line.startsWith('#') &&
            !line.startsWith('/') &&
            line.endsWith('/') &&
            !line.substring(0, line.length - 1).contains('/'))
          line.substring(0, line.length - 1),
    ];
    final sources = [
      for (final root in ['lib', 'bin', 'android/src/main', 'ios'])
        ...Directory(root).listSync(recursive: true).whereType<Directory>(),
    ];
    for (final dir in sources) {
      final segments = dir.uri.pathSegments.where((s) => s.isNotEmpty);
      expect(names.where(segments.contains), isEmpty, reason: dir.path);
    }
  });
}
