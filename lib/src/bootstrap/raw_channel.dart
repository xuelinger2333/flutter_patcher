import 'dart:async';
import 'dart:ui';
import 'package:flutter/services.dart';

typedef RawCall = Future<Object?> Function(
    String method, Map<String, Object?> arguments);

Future<Object?> rawPatcherCall(String method, Map<String, Object?> arguments) {
  const codec = StandardMethodCodec();
  final watch = method == 'bootPayload' ? (Stopwatch()..start()) : null;
  final done = Completer<Object?>();
  final encoded = codec.encodeMethodCall(MethodCall(method, arguments));
  final encodedUs = watch?.elapsedMicroseconds ?? 0;
  PlatformDispatcher.instance.sendPlatformMessage('flutter_patcher', encoded,
      (reply) {
    if (reply == null) {
      done.complete(null);
      return;
    }
    try {
      final callbackUs = watch?.elapsedMicroseconds ?? 0;
      final decoded = codec.decodeEnvelope(reply);
      if (watch != null && decoded is Map) {
        final endUs = watch.elapsedMicroseconds;
        decoded['dart_channel_us'] = {
          'encode': encodedUs,
          'callback_wait': callbackUs - encodedUs,
          'decode': endUs - callbackUs,
          'total': endUs
        };
      }
      done.complete(decoded);
    } catch (error, stack) {
      done.completeError(error, stack);
    }
  });
  return done.future;
}
