import 'dart:convert';
import 'dart:typed_data';
import 'patch_info.dart';

/// Native result distinguishes withdrawing a candidate from installing one.
class SignedUpdateResult {
  const SignedUpdateResult(this.action, this.result);
  final String action;
  final PatchApplyResult result;
}

/// An untrusted signed-manifest envelope. Parsing does not authenticate it.
/// Pass the original wire text to native verification; never trust a JSON flag.
class SignedManifest {
  SignedManifest._(this.wire, this._payload, this._signature);
  final String wire;
  final List<int> _payload;
  final List<int> _signature;
  Uint8List get payload => Uint8List.fromList(_payload);
  Uint8List get signature => Uint8List.fromList(_signature);

  factory SignedManifest.parse(String wire) {
    if (wire.length > 24000) throw const FormatException('Envelope too large');
    final json = jsonDecode(wire);
    if (json is! Map<String, dynamic> ||
        json.length != 2 ||
        json['payload'] is! String ||
        json['signature'] is! String) {
      throw const FormatException('Envelope fields');
    }
    final payload = base64.decode(json['payload'] as String);
    final signature = base64.decode(json['signature'] as String);
    final canonical = jsonEncode({
      'payload': base64.encode(payload),
      'signature': base64.encode(signature)
    });
    if (signature.length != 64 ||
        payload.isEmpty ||
        payload.length > 16384 ||
        canonical != wire) {
      throw const FormatException('Noncanonical envelope');
    }
    return SignedManifest._(
        wire, List.unmodifiable(payload), List.unmodifiable(signature));
  }
}
