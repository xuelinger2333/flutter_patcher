import 'dart:typed_data';

bool get isSupported => false;

String get operatingSystem => 'unsupported';

class PayloadDownloadException implements Exception {
  const PayloadDownloadException();
}

Uri updateUri(String url) =>
    throw UnsupportedError('Patch downloads require Android or iOS');

Future<Uint8List?> readPatchHeader(
  String url, {
  Duration timeout = const Duration(seconds: 30),
}) => throw UnsupportedError('Patch downloads require Android or iOS');

Future<String> downloadPayload(
  String url,
  int size,
  void Function(int received) progress,
) => throw UnsupportedError('Patch downloads require Android or iOS');

Future<String> writePayload(List<int> bytes) =>
    throw UnsupportedError('Patch downloads require Android or iOS');

Future<void> deletePayload(String path) async {}

Future<Uint8List> readPatchFile(String path) =>
    throw UnsupportedError('Bytecode patches require Android or iOS');
