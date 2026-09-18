import 'dart:async';
import 'package:flutter/foundation.dart';
import 'bootstrap/fonts.dart';
import 'bootstrap/transport.dart';
import 'bootstrap/runner.dart';

/// Generated build entry calls this before the application's own binding.
class PatchBootstrap {
  PatchBootstrap._();
  static bool _started = false;

  static Future<void> run(
      {required FutureOr<void> Function() original,
      required String fingerprint,
      required String publicKeyBase64,
      required ModuleLoader loadModule}) async {
    if (_started) return;
    _started = true;
    var watching = true;
    void Function()? stopObserving;
    final runner = BootRunner(
        call: BootstrapTransport().call,
        load: loadModule,
        fonts: patcherLoadFonts,
        log: (e) => debugPrint('[FlutterPatcher] $e'),
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
        });
    await runner.run(
        original: original,
        fingerprint: fingerprint,
        publicKeyBase64: publicKeyBase64);
    if (stopObserving != null)
      Timer(const Duration(seconds: 5), stopObserving!);
    // Android FlutterRenderer confirms the first frame for the armed attempt.
    // This works for both host and whole-module bindings without creating one.
  }
}
