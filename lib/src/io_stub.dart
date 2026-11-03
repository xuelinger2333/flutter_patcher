import 'dart:typed_data';

bool get isSupported => false;

String get operatingSystem => 'unsupported';

class PayloadDownloadException implements Exception {
  const PayloadDownloadException();
}

Uri updateUri(String url) =>
    throw UnsupportedError('Signed updates require Android or iOS');

Future<String?> getSignedWire(String url,
        {Duration timeout = const Duration(seconds: 30)}) =>
    throw UnsupportedError('Signed updates require Android or iOS');

Future<String> downloadPayload(
        String url, int size, void Function(int received) progress) =>
    throw UnsupportedError('Signed updates require Android or iOS');

Future<String> writePayload(List<int> bytes) =>
    throw UnsupportedError('Signed updates require Android or iOS');

Future<void> deletePayload(String path) async {}

Future<Uint8List> readPatchFile(String path) =>
    throw UnsupportedError('Bytecode patches require Android or iOS');