// Separate probe APK: this entry never starts a production boot transaction.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:crypto/crypto.dart';

const expectedHash = String.fromEnvironment('PROBE_SHA256');
const expectedLength = int.fromEnvironment('PROBE_LENGTH');

Future<void> sample(String phase, String mode) async {
  const codec = StandardMethodCodec();
  final id = '$pid:$phase:$mode';
  final watch = Stopwatch()..start();
  final message = codec.encodeMethodCall(
      MethodCall('bootPayload', {'mode': mode, 'request': id}));
  final encode = watch.elapsedMicroseconds;
  final done = Completer<void>();
  PlatformDispatcher.instance.sendPlatformMessage('wp9_probe', message,
      (response) {
    final callback = watch.elapsedMicroseconds;
    try {
      if (response == null) throw StateError('Missing probe response');
      final value = codec.decodeEnvelope(response) as Map;
      final total = watch.elapsedMicroseconds;
      final bytes = value['envelopeBytes'] as Uint8List;
      // Integrity work is deliberately outside the measured interval.
      if (value['request'] != id ||
          bytes.length != (mode == 'empty' ? 0 : expectedLength) ||
          (mode != 'empty' &&
              sha256.convert(bytes).toString() != expectedHash)) {
        throw StateError('Probe snapshot mismatch');
      }
      print('BYTECODE_PROBE_DART: ${jsonEncode({
            'request': id,
            'phase': phase,
            'mode': mode,
            'pid': pid,
            'bytes': bytes.length,
            'encode_us': encode,
            'callback_wait_us': callback - encode,
            'decode_us': total - callback,
            'total_us': total,
            'rss_bytes': ProcessInfo.currentRss,
            'max_rss_bytes': ProcessInfo.maxRss
          })}');
      done.complete();
    } catch (error, stack) {
      done.completeError(error, stack);
    }
  });
  await done.future.timeout(const Duration(seconds: 10));
}

Future<void> main() async {
  final mode = PlatformDispatcher.instance.defaultRouteName;
  await sample('cold', mode);
  WidgetsFlutterBinding.ensureInitialized();
  WidgetsBinding.instance.addPostFrameCallback((_) async {
    await Future<void>.delayed(const Duration(seconds: 1));
    await sample('post_frame', mode);
    print('BYTECODE_PROBE_DONE: $pid:$mode');
  });
  runApp(const MaterialApp(
      initialRoute: '/', home: Scaffold(body: Text('Channel probe'))));
}
