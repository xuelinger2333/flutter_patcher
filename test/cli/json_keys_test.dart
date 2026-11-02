import 'package:flutter_patcher/src/cli/core.dart';
import 'package:test/test.dart';

void main() {
  test('duplicate JSON keys are found at any depth, escaped or not', () {
    for (final ok in [
      '{"a":1,"b":{"a":2},"c":[{"a":1},{"a":2}]}',
      '{"x":"{\\"a\\":1,\\"a\\":2}","k":"a,b"}',
      '[{"a":1},{"a":1}]',
    ]) {
      rejectDuplicateJsonKeys(ok);
    }
    for (final bad in [
      '{"a":1,"a":2}',
      '{"o":{"k":[1,{"z":1,"z":2}]}}',
      '{"\\u0061":1,"a":2}',
    ]) {
      expect(() => rejectDuplicateJsonKeys(bad), throwsFormatException);
    }
  });
}
