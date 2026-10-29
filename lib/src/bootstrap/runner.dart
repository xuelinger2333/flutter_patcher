import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'patch_archive.dart';
import 'budget.dart';
import 'raw_channel.dart';

typedef ModuleLoader = Future<Object?> Function(Uint8List bytes);
typedef AssetInstaller = void Function(Map<String, Uint8List> assets);

class _NoPatch implements Exception {
  const _NoPatch();
}

/// Startup transaction; dependencies allow testing without creating a binding.
class BootRunner {
  BootRunner(
      {required this.call,
      required this.load,
      required this.fonts,
      required this.observe,
      required this.log,
      this.timeout = const Duration(seconds: 3)});
  final RawCall call;
  final ModuleLoader load;
  final Future<void> Function(Map<String, List<Uint8List>>) fonts;
  final void Function(Future<void> Function(Object) failure,
      Future<void> Function() success) observe;
  final void Function(Object) log;
  final Duration timeout;

  Future<void> run(
      {required FutureOr<void> Function() original,
      required String fingerprint,
      required String publicKeyBase64}) async {
    final startup = Stopwatch()..start();
    String? attempt;
    var failed = false, entered = false, fontMutation = false;
    Future<void> failure(Object error) async {
      log(error);
      if (failed || attempt == null) return;
      failed = true;
      try {
        await call('reportDartBootError', {
          'attempt': attempt,
          'message': error.toString(),
          'quarantine': entered || fontMutation
        }).timeout(timeout);
      } catch (e) {
        log(e);
      }
    }

    try {
      final reply = await call('bootPayload', {
        'fingerprint': fingerprint,
        'publicKeyBase64': publicKeyBase64
      }).timeout(timeout);
      final payloadUs = startup.elapsedMicroseconds;
      if (reply == null) throw const _NoPatch();
      bootRequire(reply is Map, 'Invalid boot payload');
      final row = reply as Map;
      bootRequire(
          row['attempt'] is String &&
              (row['attempt'] as String).isNotEmpty &&
              row['transportVersion'] is int &&
              row['transportVersion'] == 1 &&
              row['envelopeBytes'] is Uint8List,
          'Invalid boot attestation');
      attempt = row['attempt'] as String;
      final profile = <String, int>{};
      final bytes = row['envelopeBytes'] as Uint8List;
      final patch =
          parseAuthenticatedPatchBytes(bytes, fingerprint, profile: profile);
      final verifiedUs = startup.elapsedMicroseconds;
      final started =
          await call('markBooting', {'attempt': attempt}).timeout(timeout);
      bootRequire(started == true, 'Boot attempt expired');
      final markedUs = startup.elapsedMicroseconds;
      observe(failure, () async {
        if (failed) return;
        try {
          await call('reportBootSuccess', {'attempt': attempt})
              .timeout(timeout);
        } catch (e) {
          log(e);
        }
      });
      final beforeLoadUs = startup.elapsedMicroseconds;
      final entry = await load(patch.module);
      final loadedUs = startup.elapsedMicroseconds;
      bootRequire(!failed, 'Boot attempt already failed');
      bootRequire(entry is List && entry.length == 6, 'PatchEntry length');
      final slots = entry as List;
      bootRequire(
          slots[0] is int &&
              slots[1] is int &&
              slots[2] is String &&
              slots[3] is String &&
              slots[0] == 1 &&
              slots[1] == patch.seq &&
              slots[2] == fingerprint &&
              slots[3] == patch.tier &&
              slots[4] is FutureOr<void> Function() &&
              (patch.assets.isEmpty
                  ? slots[5] == null || slots[5] is AssetInstaller
                  : slots[5] is AssetInstaller),
          'PatchEntry contract');
      if (slots[5] != null) (slots[5] as AssetInstaller)(patch.assets);
      if (patch.fonts.isNotEmpty) {
        // Flutter has no font-unregister API. A partial registration failure
        // cannot safely run the original app in this same isolate.
        fontMutation = true;
        await fonts(patch.fonts);
      }
      bootRequire(!failed, 'Boot attempt already failed');
      entered = true;
      startup.stop();
      log('BYTECODE_BOOT_TIMING: payload_us=$payloadUs '
          'verify_us=${verifiedUs - payloadUs} '
          'load_and_handshake_us=${loadedUs - verifiedUs} '
          'resources_us=${startup.elapsedMicroseconds - loadedUs} '
          'total_us=${startup.elapsedMicroseconds}');
      log('BYTECODE_BOOT_PROFILE: ${jsonEncode({
            'schema': 2,
            'transport': 'native-bytes-v1',
            'tier': patch.tier,
            'budget_us': bootstrapBudgetUs(patch.tier),
            'native': row['profile_us'],
            'dart_channel': row['dart_channel_us'],
            'verify': profile,
            'mark_booting_us': markedUs - verifiedUs,
            'observe_us': beforeLoadUs - markedUs,
            'module_load_us': loadedUs - beforeLoadUs,
          })}');
      final budgetUs = bootstrapBudgetUs(patch.tier);
      if (startup.elapsedMicroseconds > budgetUs) {
        log('BYTECODE_BOOT_SLOW: ${startup.elapsedMicroseconds} us before patched main '
            'tier=${patch.tier} budget_us=$budgetUs');
      }
      await (slots[4] as FutureOr<void> Function())();
      return;
    } catch (error) {
      if (error is! _NoPatch) await failure(error);
      if (entered || fontMutation) return;
    }
    await original();
  }
}
