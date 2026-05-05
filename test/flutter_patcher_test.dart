import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_patcher/flutter_patcher.dart';

void main() {
  group('PatchInfo', () {
    test('parses canonical server JSON (camelCase keys)', () {
      final info = PatchInfo.fromJson({
        'version': '1.0.1-h1',
        'patchUrl': 'https://example.com/libapp.so',
        'md5': 'd41d8cd98f00b204e9800998ecf8427e',
        'signature': 'sig-base64',
        'targetVersionCode': 100,
        'mode': 'full',
      });

      expect(info.version, '1.0.1-h1');
      expect(info.patchUrl, 'https://example.com/libapp.so');
      expect(info.md5, 'd41d8cd98f00b204e9800998ecf8427e');
      expect(info.signature, 'sig-base64');
      expect(info.targetVersionCode, 100);
      expect(info.mode, PatchMode.full);
    });

    test('accepts snake_case aliases for cross-language backends', () {
      final info = PatchInfo.fromJson({
        'version': 'v2',
        'patch_url': 'https://example.com/p2.so',
        'md5': '00',
        'target_version_code': '200',
        'patchMode': 'bsdiff',
        'target_md5': 'aabb',
      });

      expect(info.patchUrl, 'https://example.com/p2.so');
      expect(info.targetVersionCode, 200);
      expect(info.mode, PatchMode.bsdiff);
      expect(info.targetMd5, 'aabb');
    });

    test('toJson omits null targetVersionCode but keeps mode', () {
      const info = PatchInfo(
        version: 'v1',
        patchUrl: 'https://example.com/x.so',
        md5: 'aa',
      );
      final json = info.toJson();
      expect(json.containsKey('targetVersionCode'), isFalse);
      expect(json['mode'], 'full');
    });
  });

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

  group('PatchCheckResult', () {
    test('hasUpdate=false yields none() with null patch', () {
      final r = PatchCheckResult.fromJson({'hasUpdate': false});
      expect(r.hasUpdate, isFalse);
      expect(r.patch, isNull);
    });

    test('has_update=false yields none() with null patch', () {
      final r = PatchCheckResult.fromJson({'has_update': false});
      expect(r.hasUpdate, isFalse);
      expect(r.patch, isNull);
    });

    test('parses nested patch map when hasUpdate=true', () {
      final r = PatchCheckResult.fromJson({
        'hasUpdate': true,
        'patch': {
          'version': 'v3',
          'patchUrl': 'https://example.com/v3.so',
          'md5': 'cc',
        },
      });
      expect(r.hasUpdate, isTrue);
      expect(r.patch?.version, 'v3');
    });

    test('parses documented flat snake_case check-update response', () {
      final r = PatchCheckResult.fromJson({
        'has_update': true,
        'version': '1.0.0-h2',
        'patch_url': 'https://example.com/arm64-v8a/libapp.so',
        'md5': '0123456789abcdef0123456789abcdef',
        'target_version_code': 100,
      });

      expect(r.hasUpdate, isTrue);
      expect(r.patch?.version, '1.0.0-h2');
      expect(r.patch?.patchUrl, 'https://example.com/arm64-v8a/libapp.so');
      expect(r.patch?.targetVersionCode, 100);
    });
  });
}
