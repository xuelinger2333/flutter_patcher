import 'dart:async';

import 'package:flutter/foundation.dart';

import 'bootstrap/assets.dart';
import 'bootstrap/fonts.dart';
import 'bootstrap/transport.dart';
import 'bootstrap/runner.dart';

/// Generated build entry calls this before the application's own binding.
/// A bytecode host passes [loadModule]; an SO host, whose patch is the
/// libapp.so already running, passes none.
class PatchBootstrap {
  PatchBootstrap._();
  static bool _started = false;

  /// This isolate's runner: the app's ([run]) or a background engine's.
  static BootRunner? _runner;
  static Future<void>? _background;

  static void _log(Object e) => debugPrint('[FlutterPatcher] $e');

  /// The generated `flutterPatcherEntry`: the engine asks it which function
  /// to run for every entry point but the root main (see [patchEntry]).
  static Function? entry(
    String key,
    Function? original, {
    required bool start,
    required String fingerprint,
    required String publicKeyBase64,
    ModuleLoader? loadModule,
  }) => patchEntry(
    key,
    original,
    start: start,
    entries: () => _runner?.entries,
    boot: () => _background ??= (_runner = BootRunner(
      call: BootstrapTransport().call,
      load: loadModule,
      assets: patcherInstallAssets,
      fonts: patcherLoadFonts,
      log: _log,
      observe: (_, _) {},
    )).background(fingerprint: fingerprint, publicKeyBase64: publicKeyBase64),
    log: _log,
  );

  static Future<void> run({
    required FutureOr<void> Function() original,
    required String fingerprint,
    required String publicKeyBase64,
    ModuleLoader? loadModule,
  }) async {
    if (_started) return;
    _started = true;
    var watching = true;
    void Function()? stopObserving;
    final runner = _runner = BootRunner(
      call: BootstrapTransport().call,
      load: loadModule,
      assets: patcherInstallAssets,
      fonts: patcherLoadFonts,
      log: _log,
      observe: (failure, onSuccess) {
        final oldPlatform = PlatformDispatcher.instance.onError;
        final oldFlutter = FlutterError.onError;
        bool onError(Object error, StackTrace stack) {
          if (watching) unawaited(failure(error));
          return oldPlatform?.call(error, stack) ?? false;
        }

        void onFlutterError(FlutterErrorDetails details) {
          if (watching) unawaited(failure(details.exception));
          oldFlutter?.call(details);
        }

        PlatformDispatcher.instance.onError = onError;
        FlutterError.onError = onFlutterError;
        stopObserving = () {
          watching = false;
          if (identical(PlatformDispatcher.instance.onError, onError)) {
            PlatformDispatcher.instance.onError = oldPlatform;
          }
          if (identical(FlutterError.onError, onFlutterError)) {
            FlutterError.onError = oldFlutter;
          }
        };
      },
    );
    await runner.run(
      original: original,
      fingerprint: fingerprint,
      publicKeyBase64: publicKeyBase64,
    );
    if (stopObserving != null) {
      Timer(const Duration(seconds: 5), stopObserving!);
    }
    // Android FlutterRenderer confirms the first frame for the armed attempt.
    // This works for both host and whole-module bindings without creating one.
  }
}
