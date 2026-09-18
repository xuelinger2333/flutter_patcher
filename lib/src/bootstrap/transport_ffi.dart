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
            'patcher_boot_v1_available'),
        input =
            library.lookupFunction<Uint64 Function(Int32), int Function(int)>(
                'patcher_boot_v1_input'),
        begin =
            library.lookupFunction<Uint64 Function(Uint64), int Function(int)>(
                'patcher_boot_v1_begin'),
        state =
            library.lookupFunction<Int32 Function(Uint64), int Function(int)>(
                'patcher_boot_v1_state'),
        size =
            library.lookupFunction<Int64 Function(Uint64), int Function(int)>(
                'patcher_boot_v1_size'),
        data = library.lookupFunction<Pointer<Uint8> Function(Uint64),
            Pointer<Uint8> Function(int)>('patcher_boot_v1_data'),
        release =
            library.lookupFunction<Int32 Function(Uint64), int Function(int)>(
                'patcher_boot_v1_release');

  final int Function() available;
  final int Function(int) input, begin, state, size, release;
  final Pointer<Uint8> Function(int) data;

  Future<Object?> call(String method, Map<String, Object?> arguments) async {
    const codec = StandardMethodCodec();
    final watch = Stopwatch()..start();
    final request = codec.encodeMethodCall(MethodCall(method, arguments));
    final buffer = input(request.lengthInBytes);
    if (buffer == 0) throw StateError('Bootstrap input rejected');
    final int task;
    try {
      data(buffer).asTypedList(request.lengthInBytes).setAll(
          0,
          request.buffer
              .asUint8List(request.offsetInBytes, request.lengthInBytes));
      task = begin(buffer);
    } finally {
      release(buffer);
    }
    if (task == 0) throw StateError('Bootstrap dispatch rejected');
    try {
      while (state(task) == 0) {
        if (watch.elapsedMilliseconds >= 2500) {
          throw TimeoutException('Bootstrap bridge deadline');
        }
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      if (state(task) != 1) throw StateError('Bootstrap worker rejected');
      final count = size(task);
      if (count <= 0 || count > 320 * 1024 * 1024 + 65536) {
        throw StateError('Bootstrap response length');
      }
      // The native view has one owner. Keep no borrowed view after release.
      final bytes = Uint8List.fromList(data(task).asTypedList(count));
      final result = codec.decodeEnvelope(ByteData.sublistView(bytes));
      if (result is Map) {
        result['dart_channel_us'] = {
          'total': watch.elapsedMicroseconds,
          'ffi': 1
        };
      }
      return result;
    } finally {
      release(task);
    }
  }
}
