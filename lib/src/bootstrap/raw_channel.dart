import 'dart:async';
import 'dart:ui';
import 'package:flutter/services.dart';

typedef RawCall = Future<Object?> Function(
    String method, Map<String, Object?> arguments);

Future<Object?> rawPatcherCall(String method, Map<String, Object?> arguments) {
  const codec = StandardMethodCodec();
  final done = Completer<Object?>();
  PlatformDispatcher.instance.sendPlatformMessage(
      'flutter_patcher', codec.encodeMethodCall(MethodCall(method, arguments)),
      (reply) {
    if (reply == null) {
      done.complete(null);
      return;
    }
    try {
      done.complete(codec.decodeEnvelope(reply));
    } catch (error, stack) {
      done.completeError(error, stack);
    }
  });
  return done.future;
}
