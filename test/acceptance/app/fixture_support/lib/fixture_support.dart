/// Host-side helpers for the device acceptance fixture. A dependency stays in
/// the host's AOT code, so a lean patch calls these functions instead of
/// carrying FFI, which the interpreter cannot execute in an AOT runtime.
library;

import 'dart:convert';
import 'dart:ffi';

/// NSHomeDirectory() of this iOS app (Platform.environment is empty there).
String iosHome() {
  final process = DynamicLibrary.process();
  final malloc = process
      .lookupFunction<
        Pointer<Uint8> Function(IntPtr),
        Pointer<Uint8> Function(int)
      >('malloc');
  final selector = utf8.encode('UTF8String');
  final name = malloc(selector.length + 1);
  for (var i = 0; i < selector.length; i++) {
    name[i] = selector[i];
  }
  name[selector.length] = 0;
  final home = process
      .lookupFunction<Pointer<Void> Function(), Pointer<Void> Function()>(
        'NSHomeDirectory',
      )();
  final register = process
      .lookupFunction<
        Pointer<Void> Function(Pointer<Uint8>),
        Pointer<Void> Function(Pointer<Uint8>)
      >('sel_registerName');
  final send = process
      .lookupFunction<
        Pointer<Uint8> Function(Pointer<Void>, Pointer<Void>),
        Pointer<Uint8> Function(Pointer<Void>, Pointer<Void>)
      >('objc_msgSend');
  final text = send(home, register(name));
  final bytes = <int>[];
  for (var i = 0; text[i] != 0; i++) {
    bytes.add(text[i]);
  }
  return utf8.decode(bytes);
}
