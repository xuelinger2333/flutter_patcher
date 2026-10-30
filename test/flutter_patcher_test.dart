import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_patcher/flutter_patcher.dart';

void main() {
  group('PatchApplyResult', () {
    test('success native map yields ok result', () {
      final r = PatchApplyResult.fromNative({'ok': true});
      expect(r.ok, isTrue);
      expect(r.error, isNull);
    });

    test('maps known native error codes to typed enum', () {
      final r = PatchApplyResult.fromNative({
        'ok': false,
        'error': 'SIGNATURE_INVALID',
        'message': 'bad sig',
      });
      expect(r.ok, isFalse);
      expect(r.error, PatchApplyError.signatureInvalid);
      expect(r.message, 'bad sig');
    });

    test('unknown error codes degrade to PatchApplyError.unknown', () {
      final r = PatchApplyResult.fromNative({'ok': false, 'error': 'NEW_CODE'});
      expect(r.error, PatchApplyError.unknown);
    });
  });

  group('PatchApplyProgress', () {
    test('downloading phase reports fraction when total is known', () {
      final p = PatchApplyProgress.fromNative({
        'phase': 'downloading',
        'received': 50,
        'total': 200,
      });
      expect(p.phase, PatchApplyPhase.downloading);
      expect(p.fraction, 0.25);
    });

    test('non-downloading phases have null fraction', () {
      final p = PatchApplyProgress.fromNative({'phase': 'verifying'});
      expect(p.phase, PatchApplyPhase.verifying);
      expect(p.fraction, isNull);
    });
  });
}
