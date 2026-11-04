import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter/services.dart';

import 'raw_channel.dart';

RawCall? openBootstrapTransport() {
  if (!Platform.isAndroid) return null;
  try {
    final bridge = _Bridge(DynamicLibrary.open('libpatcher_boot.so'));
    return bridge.available() == 1 ? bridge.call : null;
  } on ArgumentError {
    // Old APK or missing ABI/symbol: no request has reached native yet.
    return null;
  }
}

class _Bridge {
  _Bridge(DynamicLibrary library)
    : available = library.lookupFunction<Int32 Function(), int Function()>(
        'patcher_boot_v1_available',
      ),
      input = library.lookupFunction<Uint64 Function(Int32), int Function(int)>(
        'patcher_boot_v1_input',
      ),
      begin = library
          .lookupFunction<Uint64 Function(Uint64), int Function(int)>(
            'patcher_boot_v1_begin',
          ),
      state = library.lookupFunction<Int32 Function(Uint64), int Function(int)>(
        'patcher_boot_v1_state',
      ),
      size = library.lookupFunction<Int64 Function(Uint64), int Function(int)>(
        'patcher_boot_v1_size',
      ),
      data = library
          .lookupFunction<
            Pointer<Uint8> Function(Uint64),
            Pointer<Uint8> Function(int)
          >('patcher_boot_v1_data'),
      release = library
          .lookupFunction<Int32 Function(Uint64), int Function(int)>(
            'patcher_boot_v1_release',
          ),
      span = library
          .lookupFunction<
            Int64 Function(Uint64, Int32),
            int Function(int, int)
          >('patcher_boot_v1_span');

  final int Function() available;
  final int Function(int) input, begin, state, size, release;
  final Pointer<Uint8> Function(int) data;
  final int Function(int, int) span;

  Future<Object?> call(String method, Map<String, Object?> arguments) async {
    const codec = StandardMethodCodec();
    final watch = Stopwatch()..start();
    var checkpoint = 0;
    final spans = <String, int>{};
    void mark(String name) {
      final now = watch.elapsedMicroseconds;
      spans[name] = now - checkpoint;
      checkpoint = now;
    }

    final request = codec.encodeMethodCall(MethodCall(method, arguments));
    final buffer = input(request.lengthInBytes);
    if (buffer == 0) throw StateError('Bootstrap input rejected');
    final int task;
    try {
      data(buffer)
          .asTypedList(request.lengthInBytes)
          .setAll(
            0,
            request.buffer.asUint8List(
              request.offsetInBytes,
              request.lengthInBytes,
            ),
          );
      task = begin(buffer);
    } finally {
      release(buffer);
    }
    if (task == 0) throw StateError('Bootstrap dispatch rejected');
    mark('encode_and_begin');
    try {
      while (state(task) == 0) {
        if (watch.elapsedMilliseconds >= 2500) {
          throw TimeoutException('Bootstrap bridge deadline');
        }
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      if (state(task) != 1) throw StateError('Bootstrap worker rejected');
      mark('wait');
      final count = size(task);
      if (count < 4 || count > 320 * 1024 * 1024 + 65536) {
        throw StateError('Bootstrap response length');
      }
      // The native view has one owner. Keep no borrowed view after release.
      final bytes = Uint8List.fromList(data(task).asTypedList(count));
      mark('copy');
      // The codec envelope's length, the envelope, then an offer's
      // envelopeBytes unencoded (see BootstrapBridge.execute).
      final head = ByteData.sublistView(bytes).getUint32(0);
      if (head > count - 4) throw StateError('Bootstrap response length');
      final result = codec.decodeEnvelope(
        ByteData.sublistView(bytes, 4, 4 + head),
      );
      final tail = Uint8List.sublistView(bytes, 4 + head);
      if (tail.isNotEmpty) {
        if (result is! Map || result.containsKey('envelopeBytes')) {
          throw StateError('Bootstrap response layout');
        }
        result['envelopeBytes'] = tail;
      }
      mark('decode');
      if (result is Map) {
        result['dart_channel_us'] = {
          'total': watch.elapsedMicroseconds,
          'ffi': 1,
          ...spans,
          for (final (i, name) in const [
            'worker_start',
            'attach',
            'kotlin',
            'jni_copy',
          ].indexed)
            'native_$name': span(task, i),
        };
      }
      return result;
    } finally {
      release(task);
    }
  }
}
