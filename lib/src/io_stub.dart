import 'dart:typed_data';

bool get isAndroid => false;

String get operatingSystem => 'unsupported';

Future<Map<String, dynamic>> getJson(
  String url, {
  Map<String, String>? headers,
  Duration timeout = const Duration(seconds: 10),
}) {
  throw UnsupportedError('flutter_patcher only supports Android');
}

Future<String> stagePatchBytes(String dir, Uint8List bytes) {
  throw UnsupportedError('flutter_patcher only supports Android');
}

Future<void> deleteFileIfExists(String path) async {}
