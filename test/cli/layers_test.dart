import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'package:flutter_patcher/src/cli/core.dart';
import 'package:flutter_patcher/src/cli/patch/package.dart';
import 'package:flutter_patcher/src/cli/publish/pipeline.dart';

/// The CLI libraries [file] reaches through relative imports and exports.
Set<String> reached(String file) {
  final seen = <String>{};
  void visit(String path) {
    if (!seen.add(p.normalize(path))) return;
    final text = File(path).readAsStringSync();
    for (final match in RegExp(
      r"^(?:import|export) '([^':]+\.dart)'",
      multiLine: true,
    ).allMatches(text)) {
      visit(p.join(p.dirname(path), match.group(1)!));
    }
  }

  visit(file);
  return seen;
}

void main() {
  test('patch and build cannot reach private keys', () {
    final forbidden = {
      for (final name in [
        'keys/keyring.dart',
        'keys/signer.dart',
        'publish/seal.dart',
      ])
        p.normalize(p.join('lib/src/cli', name)),
    };
    for (final layer in ['lib/src/cli/patch', 'lib/src/cli/build']) {
      for (final file in Directory(layer).listSync().whereType<File>()) {
        expect(
          reached(file.path).intersection(forbidden),
          isEmpty,
          reason: file.path,
        );
      }
    }
  });

  group('patch sequences', () {
    Matcher conflict(String text) => throwsA(
      isA<Failure>()
          .having((f) => f.code, 'code', 'PUBLISH_SEQUENCE_CONFLICT')
          .having((f) => f.message, 'message', contains(text)),
    );

    test(
      'publication sequence is independent of clocks and module identity',
      () {
        final id = newModuleId();
        expect(id, inInclusiveRange(1, 1 << 52));
        checkSequence(1, 1);
        checkSequence(10, 2);
        expect(() => checkSequence(1, 2), conflict('older'));
        expect(() => checkSequence(0x100000000, 1), conflict('4294967295'));
      },
    );
  });
}
