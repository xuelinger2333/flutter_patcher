import 'raw_channel.dart';
import 'transport_stub.dart' if (dart.library.ffi) 'transport_ffi.dart'
    as native;

/// Select once, before consuming a boot offer. Errors never replay a request.
class BootstrapTransport {
  BootstrapTransport({RawCall? Function()? open, RawCall? channel})
      : _open = open ?? native.openBootstrapTransport,
        _channel = channel ?? rawPatcherCall;

  final RawCall? Function() _open;
  final RawCall _channel;
  RawCall? _selected;

  Future<Object?> call(String method, Map<String, Object?> arguments) {
    switch (method) {
      case 'bootPayload':
        _selected ??= _open() ?? _channel;
        return _selected!(method, arguments);
      case 'markBooting':
        return (_selected ?? _channel)(method, arguments);
      default:
        return _channel(method, arguments);
    }
  }
}
