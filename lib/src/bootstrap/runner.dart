import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'patch_archive.dart';
import 'budget.dart';
import 'raw_channel.dart';

typedef ModuleLoader = Future<Object?> Function(Uint8List bytes);

/// What the engine runs for the entry point [key] (`library#name` or
/// `library#Class.name` of the host's declaration), found as [original]
/// (null when this isolate has none by that name); see the generated
/// `flutterPatcherEntry`.
///
/// A callback looked up by an isolate ([start] false) is the loaded patch's
/// version, when [entries] has one. An entry point that starts a background
/// isolate ([start] true) first boots it with [boot], once, and then runs
/// the patch's version or [original]; the engine calls it as it would a
/// main.
Function? patchEntry(
  String key,
  Function? original, {
  required bool start,
  required Map<String, Function>? Function() entries,
  required Future<void> Function() boot,
  required void Function(Object) log,
}) {
  if (!start) return entries()?[key] ?? original;
  return (List<String> args) async {
    try {
      await boot();
    } catch (error) {
      log('Background boot failed for $key: $error');
    }
    final patched = entries()?[key];
    final target = patched ?? original;
    if (target == null) throw StateError('No entry point $key');
    if (patched != null) log('Background entry $key runs the patch');
    return target is Object? Function(List<String>)
        ? target(args)
        : Function.apply(target, const []);
  };
}

class _NoPatch implements Exception {
  const _NoPatch();
}

/// What a boot payload asks of this process before the app's main.
class _Boot {
  _Boot(this.assets, this.fonts, {this.patch});

  /// Present for a bytecode host: the module to load and its patched main.
  final VerifiedPatch? patch;
  final Map<String, Uint8List> assets;
  final Map<String, List<Uint8List>> fonts;
}

/// Startup transaction; dependencies allow testing without creating a binding.
///
/// Both strategies share it. A bytecode host receives the authenticated patch
/// envelope and runs the module's main. An SO host already runs the patched
/// libapp.so, which native code verified and loaded; it receives only the
/// patch's resources and then runs its own main.
///
/// [run] boots the app's isolate as one attempt; [background] boots an
/// isolate a background engine starts, with the same code and resources but
/// no attempt.
class BootRunner {
  BootRunner({
    required this.call,
    this.load,
    required this.assets,
    required this.fonts,
    required this.observe,
    required this.log,
    this.timeout = const Duration(seconds: 3),
  });
  final RawCall call;

  /// Null on an SO host, which never loads a module.
  final ModuleLoader? load;
  final Future<void> Function(Map<String, Uint8List>) assets;
  final Future<void> Function(Map<String, List<Uint8List>>) fonts;
  final void Function(
    Future<void> Function(Object) failure,
    Future<void> Function() success,
  )
  observe;
  final void Function(Object) log;
  final Duration timeout;

  /// The loaded module's entry points by host key; empty for a module
  /// without them, null until a module loads (and always on an SO host).
  Map<String, Function>? entries;

  Future<void> run({
    required FutureOr<void> Function() original,
    required String fingerprint,
    required String publicKeyBase64,
  }) async {
    final startup = Stopwatch()..start();
    String? attempt;
    var failed = false, entered = false, mutated = false, libapp = false;
    Future<void> failure(Object error) async {
      log(error);
      if (failed || attempt == null) return;
      failed = true;
      try {
        await call('reportDartBootError', {
          'attempt': attempt,
          'message': error.toString(),
          'quarantine': entered || mutated,
        }).timeout(timeout);
      } catch (e) {
        log(e);
      }
    }

    try {
      final reply = await call('bootPayload', {
        'fingerprint': fingerprint,
        'publicKeyBase64': publicKeyBase64,
      }).timeout(timeout);
      final payloadUs = startup.elapsedMicroseconds;
      if (reply == null) throw const _NoPatch();
      bootRequire(reply is Map, 'Invalid boot payload');
      final row = reply as Map;
      bootRequire(
        row['attempt'] is String &&
            (row['attempt'] as String).isNotEmpty &&
            row['transportVersion'] is int &&
            row['transportVersion'] == 1,
        'Invalid boot attestation',
      );
      attempt = row['attempt'] as String;
      libapp = row['kind'] == 'libapp';
      final profile = <String, int>{};
      final boot = libapp
          ? _resources(row)
          : _bytecode(row, fingerprint, profile);
      final verifiedUs = startup.elapsedMicroseconds;
      final started = await call('markBooting', {
        'attempt': attempt,
      }).timeout(timeout);
      bootRequire(started == true, 'Boot attempt expired');
      final markedUs = startup.elapsedMicroseconds;
      observe(failure, () async {
        if (failed) return;
        try {
          await call('reportBootSuccess', {
            'attempt': attempt,
          }).timeout(timeout);
        } catch (e) {
          log(e);
        }
      });
      final beforeLoadUs = startup.elapsedMicroseconds;
      final patch = boot.patch;
      FutureOr<void> Function() main = original;
      if (patch != null) {
        main = await _enter(patch, fingerprint);
        bootRequire(!failed, 'Boot attempt already failed');
      }
      final loadedUs = startup.elapsedMicroseconds;
      // The engine has no API to remove installed assets or registered fonts.
      // After a partial failure the original app cannot safely run in this
      // same isolate.
      await _install(boot, () => mutated = true);
      bootRequire(!failed, 'Boot attempt already failed');
      entered = true;
      startup.stop();
      log(
        '${libapp ? 'SO' : 'BYTECODE'}_BOOT_TIMING: payload_us=$payloadUs '
        'verify_us=${verifiedUs - payloadUs} '
        'load_and_handshake_us=${loadedUs - verifiedUs} '
        'resources_us=${startup.elapsedMicroseconds - loadedUs} '
        'total_us=${startup.elapsedMicroseconds}',
      );
      if (patch != null) {
        log(
          'BYTECODE_BOOT_PROFILE: ${jsonEncode({'schema': 2, 'transport': 'native-bytes-v1', 'tier': patch.tier, 'budget_us': bootstrapBudgetUs(patch.tier), 'native': row['profile_us'], 'bridge': row['bridge_us'], 'dart_channel': row['dart_channel_us'], 'verify': profile, 'mark_booting_us': markedUs - verifiedUs, 'observe_us': beforeLoadUs - markedUs, 'module_load_us': loadedUs - beforeLoadUs})}',
        );
        final budgetUs = bootstrapBudgetUs(patch.tier);
        if (startup.elapsedMicroseconds > budgetUs) {
          log(
            'BYTECODE_BOOT_SLOW: ${startup.elapsedMicroseconds} us before patched main '
            'tier=${patch.tier} budget_us=$budgetUs',
          );
        }
      }
      await main();
      return;
    } catch (error) {
      if (error is! _NoPatch) await failure(error);
      if (entered) return;
      // An SO process already runs the patch's code and has no other main:
      // it continues without the resources the failure left out, and the
      // reported failure rolls the patch back for the next start.
      if (mutated && !libapp) return;
    }
    await original();
  }

  /// Boots an isolate a background engine starts: the code and resources
  /// this process boots with, offered without an attempt, so the isolate
  /// neither starts, settles nor fails one. Leaves [entries] null when no
  /// module is in effect; failures are the caller's to log.
  Future<void> background({
    required String fingerprint,
    required String publicKeyBase64,
  }) async {
    final startup = Stopwatch()..start();
    final reply = await call('backgroundPayload', {
      'fingerprint': fingerprint,
      'publicKeyBase64': publicKeyBase64,
    }).timeout(timeout);
    if (reply == null) return;
    bootRequire(
      reply is Map && reply['transportVersion'] == 1,
      'Invalid background payload',
    );
    final row = reply as Map;
    final libapp = row['kind'] == 'libapp';
    final boot = libapp ? _resources(row) : _bytecode(row, fingerprint, {});
    if (boot.patch != null) await _enter(boot.patch!, fingerprint);
    await _install(boot, () {});
    log(
      'BACKGROUND_BOOT_TIMING: kind=${libapp ? 'libapp' : 'bytecode'} '
      'entries=${entries?.length ?? 0} '
      'total_us=${startup.elapsedMicroseconds}',
    );
  }

  /// Loads [patch]'s module, checks its PatchEntry, records its [entries]
  /// and returns its main.
  Future<FutureOr<void> Function()> _enter(
    VerifiedPatch patch,
    String fingerprint,
  ) async {
    final loader = load;
    bootRequire(loader != null, 'Host cannot load modules');
    final entry = await loader!(patch.module);
    bootRequire(entry is List && entry.length == 6, 'PatchEntry length');
    final slots = entry as List;
    final table = slots[5];
    bootRequire(
      slots[0] is int &&
          slots[1] is int &&
          slots[2] is String &&
          slots[3] is String &&
          slots[0] == 1 &&
          slots[1] == patch.moduleId &&
          slots[2] == fingerprint &&
          slots[3] == patch.tier &&
          slots[4] is FutureOr<void> Function() &&
          (table == null ||
              table is Map &&
                  table.entries.every(
                    (e) => e.key is String && e.value is Function,
                  )),
      'PatchEntry contract',
    );
    entries = {
      for (final e in (table as Map? ?? const {}).entries)
        e.key as String: e.value as Function,
    };
    return slots[4] as FutureOr<void> Function();
  }

  /// Hands [boot]'s resources to the engine; [mutating] precedes each change.
  Future<void> _install(_Boot boot, void Function() mutating) async {
    if (boot.assets.isNotEmpty) {
      mutating();
      await assets(boot.assets);
    }
    if (boot.fonts.isNotEmpty) {
      mutating();
      await fonts(boot.fonts);
    }
  }

  _Boot _bytecode(Map row, String fingerprint, Map<String, int> profile) {
    bootRequire(
      row['kind'] == null || row['kind'] == 'bytecode',
      'Invalid boot attestation',
    );
    bootRequire(row['envelopeBytes'] is Uint8List, 'Invalid boot attestation');
    final patch = parseAuthenticatedPatchBytes(
      row['envelopeBytes'] as Uint8List,
      fingerprint,
      checkedEntries: row['entries'],
      profile: profile,
    );
    return _Boot(patch.assets, patch.fonts, patch: patch);
  }

  /// Native verified the signed envelope and each entry's digest.
  _Boot _resources(Map row) {
    final assets = row['assets'], fonts = row['fonts'];
    bootRequire(
      assets is Map &&
          fonts is Map &&
          assets.entries.every(
            (e) => e.key is String && e.value is Uint8List,
          ) &&
          fonts.entries.every(
            (e) =>
                e.key is String &&
                (e.key as String).isNotEmpty &&
                e.value is List &&
                (e.value as List).isNotEmpty &&
                (e.value as List).every((v) => v is Uint8List),
          ),
      'Invalid boot resources',
    );
    return _Boot(
      {
        for (final e in (assets as Map).entries)
          e.key as String: e.value as Uint8List,
      },
      {
        for (final e in (fonts as Map).entries)
          e.key as String: List<Uint8List>.from(e.value as List),
      },
    );
  }
}
