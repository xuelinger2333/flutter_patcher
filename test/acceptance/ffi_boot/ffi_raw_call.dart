// Experimental transport selector; only generated disposable builds import this.
import 'dart:async';
import 'dart:ffi';
import 'dart:typed_data';
import 'dart:ui';
import 'package:flutter/services.dart';
import 'raw_channel.dart';

final _lib = DynamicLibrary.open('libwp24_boot.so');
final _input = _lib
    .lookupFunction<Uint64 Function(Int32), int Function(int)>('wp24_input');
final _begin = _lib
    .lookupFunction<Uint64 Function(Uint64), int Function(int)>('wp24_begin');
final _state = _lib
    .lookupFunction<Int32 Function(Uint64), int Function(int)>('wp24_state');
final _size =
    _lib.lookupFunction<Int64 Function(Uint64), int Function(int)>('wp24_size');
final _data = _lib.lookupFunction<Pointer<Uint8> Function(Uint64),
    Pointer<Uint8> Function(int)>('wp24_data');
final _release = _lib
    .lookupFunction<Int32 Function(Uint64), int Function(int)>('wp24_release');
final _workers =
    _lib.lookupFunction<Int32 Function(), int Function()>('wp24_workers');
final _handles =
    _lib.lookupFunction<Int32 Function(), int Function()>('wp24_handles');

Future<Object?> wp24RawCall(String method, Map<String, Object?> args) async {
  if (PlatformDispatcher.instance.defaultRouteName != 'ffi' ||
      !['bootPayload', 'markBooting'].contains(method)) {
    return rawPatcherCall(method, args);
  }
  const codec = StandardMethodCodec();
  final watch = Stopwatch()..start();
  final task = _start(method, args);
  try {
    while (_state(task) == 0) {
      if (watch.elapsedMilliseconds >= 2500)
        throw TimeoutException('Bridge operation deadline');
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    if (_state(task) != 1) throw StateError('Bridge worker rejected');
    final count = _size(task);
    if (count <= 0 || count > 320 * 1024 * 1024 + 65536)
      throw StateError('Bridge response length');
    final bytes = Uint8List.fromList(_data(task).asTypedList(count));
    final result = codec.decodeEnvelope(ByteData.sublistView(bytes));
    if (result is Map)
      result['dart_channel_us'] = {'total': watch.elapsedMicroseconds, 'ffi': 1};
    return result;
  } finally {
    _release(task);
  }
}

int _start(String method, Map<String, Object?> args) {
  const codec = StandardMethodCodec();
  final request = codec.encodeMethodCall(MethodCall(method, args));
  final input = _input(request.lengthInBytes);
  if (input == 0) throw StateError('Bridge input allocation rejected');
  int task;
  try {
    _data(input).asTypedList(request.lengthInBytes).setAll(
        0,
        request.buffer
            .asUint8List(request.offsetInBytes, request.lengthInBytes));
    task = _begin(input);
  } finally {
    _release(input);
  }
  if (task == 0) throw StateError('Bridge dispatch rejected');
  return task;
}

Future<void> wp24OwnershipChecks() async {
  if (_input(-1) != 0 || _input(65537) != 0 || _release(0) != -1)
    throw StateError('Bounds');
  for (var i = 0; i < 100; i++) {
    final h = _input(8);
    if (h == 0 ||
        _size(h) != 8 ||
        _release(h) != 0 ||
        _release(h) != -1 ||
        _size(h) != -1 ||
        _data(h).address != 0) throw StateError('Lifecycle');
  }
  final first = _start('wp24_delay', {}), second = _start('wp24_delay', {});
  await Future<void>.delayed(const Duration(milliseconds: 50));
  if (_workers() != 2 || _state(first) != 0 || _state(second) != 0)
    throw StateError('Missing live workers');
  _release(first);
  _release(second);
  var rejected = false;
  try {
    final unexpected = _start('wp24_delay', {});
    _release(unexpected);
  } on StateError {
    rejected = true;
  }
  if (!rejected || _handles() != 0)
    throw StateError('Cancelled work bypassed capacity bound');
  await Future<void>.delayed(const Duration(milliseconds: 700));
  if (_workers() != 0 || _handles() != 0 || _state(first) != -2)
    throw StateError('Late result leaked');
}
