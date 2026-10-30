import 'dart:typed_data';

bool get isAndroid => false;

String get operatingSystem => 'unsupported';

Future<String> getSignedWire(String url,
        {Duration timeout = const Duration(seconds: 30)}) =>
    throw UnsupportedError('Signed updates require Android');

Future<Uint8List> readPatchFile(String path) =>
    throw UnsupportedError('Bytecode patches require Android');
