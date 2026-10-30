import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

bool get isSupported => Platform.isAndroid || Platform.isIOS;

String get operatingSystem => Platform.operatingSystem;

/// Retain signed wire bytes. HTTPS only; redirects and ambient credentials are
/// deliberately unsupported so a response cannot forward a signed download URL.
Future<String> getSignedWire(String url,
    {Duration timeout = const Duration(seconds: 30)}) async {
  final uri = Uri.parse(url);
  if (uri.scheme != 'https' ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasFragment) {
    throw const FormatException(
        'Signed updates require HTTPS without URL credentials');
  }
  final client = HttpClient()..connectionTimeout = timeout;
  Future<String> read() async {
    final request = await client.getUrl(uri);
    request.followRedirects = false;
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    final response = await request.close();
    if (response.statusCode != 200 || response.contentLength > 24000) {
      throw const FormatException('Signed update response rejected');
    }
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in response) {
      if (bytes.length + chunk.length > 24000) {
        throw const FormatException('Signed update response too large');
      }
      bytes.add(chunk);
    }
    return utf8.decode(bytes.takeBytes());
  }

  try {
    return await read().timeout(timeout);
  } catch (_) {
    throw const FormatException('Signed update download failed');
  } finally {
    client.close(force: true);
  }
}

/// Bound allocation by the actual open file, never by its FPTC header.
Future<Uint8List> readPatchFile(String path) async {
  final file = await File(path).open();
  try {
    final length = await file.length();
    if (length < 146 || length > 320 * 1024 * 1024) {
      throw const FormatException('Patch size');
    }
    final bytes = await file.read(length);
    if (bytes.length != length) throw const FormatException('Patch truncated');
    return bytes;
  } finally {
    await file.close();
  }
}
