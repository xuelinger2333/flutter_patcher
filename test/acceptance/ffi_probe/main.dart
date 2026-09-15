// Independent transport experiment; never starts a patch transaction.
import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

final library = DynamicLibrary.open('libwp24_transport.so');
final acquire = library
    .lookupFunction<Uint64 Function(Int32), int Function(int)>('wp24_acquire');
final data = library.lookupFunction<Pointer<Uint8> Function(Uint64),
    Pointer<Uint8> Function(int)>('wp24_data');
final length = library
    .lookupFunction<Int64 Function(Uint64), int Function(int)>('wp24_length');
final release = library
    .lookupFunction<Int32 Function(Uint64), int Function(int)>('wp24_release');
final retained =
    library.lookupFunction<Int64 Function(), int Function()>('wp24_retained');
final cpu =
    library.lookupFunction<Int64 Function(), int Function()>('wp24_cpu_ns');
final peak =
    library.lookupFunction<Int64 Function(), int Function()>('wp24_peak_rss');

Future<Object?> channel(String method, [Map<String, Object?> args = const {}]) {
  const codec = StandardMethodCodec();
  final done = Completer<Object?>();
  PlatformDispatcher.instance.sendPlatformMessage(
      'wp24_probe', codec.encodeMethodCall(MethodCall(method, args)), (reply) {
    try {
      if (reply == null) throw StateError('Missing response');
      done.complete(codec.decodeEnvelope(reply));
    } catch (e, s) {
      done.completeError(e, s);
    }
  });
  return done.future.timeout(const Duration(seconds: 20));
}

Uint8List readFfi(int size) {
  final handle = acquire(size);
  if (handle == 0) throw StateError('Bridge acquisition failed');
  try {
    if (length(handle) != size) throw StateError('Length mismatch');
    return size == 0
        ? Uint8List(0)
        : Uint8List.fromList(data(handle).asTypedList(size));
  } finally {
    if (release(handle) != 0) throw StateError('Release failed');
  }
}

Future<void> sample(String phase, String mode, int size) async {
  final beforeCpu = cpu();
  final watch = Stopwatch()..start();
  final Uint8List bytes;
  Object? spans;
  if (mode == 'ffi') {
    bytes = readFfi(size);
  } else {
    final response = await channel('bytes', {'size': size}) as Map;
    bytes = response['bytes'] as Uint8List;
    spans = {
      for (final name in ['worker_queue_us', 'read_us', 'main_queue_us'])
        name: response[name]
    };
  }
  final us = watch.elapsedMicroseconds, cpuUs = (cpu() - beforeCpu) ~/ 1000;
  final peakRss = peak();
  // Exact deterministic content validation is outside the measured interval.
  if (bytes.length != size || retained() != 0)
    throw StateError('Ownership/length failed');
  for (var i = 0; i < bytes.length; i++) {
    if (bytes[i] != (i % 251)) throw StateError('Byte mismatch');
  }
  print('WP24_SAMPLE: ${jsonEncode({
        'phase': phase,
        'mode': mode,
        'size': size,
        'pid': pid,
        'total_us': us,
        'cpu_us': cpuUs,
        'peak_rss_bytes': peakRss,
        'rss_bytes': ProcessInfo.currentRss,
        'native': spans
      })}');
}

void ownershipChecks() {
  if (acquire(-1) != 0 || acquire(16777217) != 0 || release(0) != -1)
    throw StateError('Bounds/handle rejection');
  for (var i = 0; i < 100; i++) {
    final h = acquire(65536);
    if (h == 0 ||
        length(h) != 65536 ||
        release(h) != 0 ||
        release(h) != -1 ||
        length(h) != -1 ||
        data(h).address != 0) {
      throw StateError('Handle lifecycle');
    }
  }
  if (retained() != 0) throw StateError('Retained buffers');
}

Future<void> main() async {
  final config = PlatformDispatcher.instance.defaultRouteName.split(':');
  final mode = config[0], size = int.parse(config[1]);
  if (!['channel', 'ffi'].contains(mode)) throw StateError('Unknown mode');
  final init = Stopwatch()..start();
  library;
  acquire;
  data;
  length;
  release;
  retained;
  cpu;
  peak;
  final initUs = init.elapsedMicroseconds;
  await sample('cold', mode, size);
  WidgetsFlutterBinding.ensureInitialized();
  WidgetsBinding.instance.addPostFrameCallback((_) async {
    await Future<void>.delayed(const Duration(seconds: 1));
    await sample('post_frame', mode, size);
    ownershipChecks();
    final info = await channel('info');
    print('WP24_DONE: ${jsonEncode({
          'pid': pid,
          'dart_init_us': initUs,
          'native_init': info,
          'ownership': 'passed'
        })}');
  });
  runApp(const MaterialApp(
      initialRoute: '/', home: Scaffold(body: Text('WP24 transport probe'))));
}
