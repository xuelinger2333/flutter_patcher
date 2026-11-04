import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'package:flutter_patcher/src/cli/core.dart';
import 'package:flutter_patcher/src/cli/patch/package.dart';
import 'package:flutter_patcher/src/cli/publish/command.dart';

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
    test('order patches by when they were made', () {
      final made = DateTime.utc(2026, 11, 5, 8);
      final seq = patchSequence(made);
      expect(sequenceTime(seq), made);
      expect(patchSequence(made.add(const Duration(seconds: 1))), seq + 1);
      expect(seq, lessThan(0xffffffff));
      expect(patchSequence(DateTime.utc(2161)), lessThan(0xffffffff));
    });

    Matcher conflict(String text) => throwsA(
      isA<Failure>()
          .having((f) => f.code, 'code', 'PUBLISH_SEQUENCE_CONFLICT')
          .having((f) => f.message, 'message', contains(text)),
    );

    test('publish takes only a newer patch made before now', () {
      final now = DateTime.utc(2026, 11, 5);
      final seq = patchSequence(now);
      checkSequence(seq, seq, now: now);
      checkSequence(seq, 1, now: now);
      expect(() => checkSequence(seq, seq + 1, now: now), conflict('older'));
      // A machine whose clock runs ahead would shut out later patches.
      checkSequence(
        patchSequence(now.add(const Duration(hours: 23))),
        1,
        now: now,
      );
      expect(
        () => checkSequence(
          patchSequence(now.add(const Duration(days: 2))),
          1,
          now: now,
        ),
        conflict('clock'),
      );
    });
  });
}
