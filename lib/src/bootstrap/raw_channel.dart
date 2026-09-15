import 'dart:async';
import 'dart:convert';
import 'dart:ui';
import 'package:flutter/services.dart';

typedef RawCall = Future<Object?> Function(
    String method, Map<String, Object?> arguments);

int _profileSequence = 0;

Future<Object?> rawPatcherCall(String method, Map<String, Object?> arguments) {
  const codec = StandardMethodCodec();
  final watch = method == 'bootPayload' || method == 'markBooting'
      ? (Stopwatch()..start())
      : null;
  final request = watch == null ? null : 'raw-${_profileSequence++}';
  final done = Completer<Object?>();
  final encoded = codec.encodeMethodCall(MethodCall(method,
      request == null ? arguments : {...arguments, 'profileRequest': request}));
  final encodedUs = watch?.elapsedMicroseconds ?? 0;
  void record(String outcome, int callbackUs) {
    if (watch == null) return;
    final endUs = watch.elapsedMicroseconds;
    // [PROFILE] Emit after measured work; never log arguments or error text.
    // ignore: avoid_print
    print('BYTECODE_DART_CHANNEL_TIMING: ${jsonEncode({
          'schema': 1,
          'method': method,
          'request': request,
          'outcome': outcome,
          'encode_us': encodedUs,
          'callback_wait_us': callbackUs - encodedUs,
          'decode_us': endUs - callbackUs,
          'total_us': endUs,
        })}');
  }

  PlatformDispatcher.instance.sendPlatformMessage('flutter_patcher', encoded,
      (reply) {
    final callbackUs = watch?.elapsedMicroseconds ?? 0;
    if (reply == null) {
      record('missing', callbackUs);
      done.complete(null);
      return;
    }
    try {
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
      record(decoded == null ? 'empty' : 'success', callbackUs);
      done.complete(decoded);
    } catch (error, stack) {
      record('error', callbackUs);
      done.completeError(error, stack);
    }
  });
  return done.future;
}
