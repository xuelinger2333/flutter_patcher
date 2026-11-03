import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

bool get isSupported => Platform.isAndroid || Platform.isIOS;

String get operatingSystem => Platform.operatingSystem;

/// A failed transfer; a later retry may succeed.
class PayloadDownloadException implements Exception {
  const PayloadDownloadException();
  @override
  String toString() => 'Patch download failed';
}

/// HTTPS, or HTTP to this device itself, where `flutter_patcher serve` is
/// reached through adb reverse: signatures, not transport, authenticate
/// updates. Redirects and ambient credentials are deliberately unsupported
/// so a response cannot forward a signed download elsewhere.
Uri updateUri(String url) {
  final uri = Uri.parse(url);
  final local = uri.scheme == 'http' &&
      const {'127.0.0.1', '::1', 'localhost'}.contains(uri.host);
  if (!(uri.scheme == 'https' || local) ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasFragment) {
    throw const FormatException(
        'Signed updates require HTTPS without URL credentials');
  }
  return uri;
}

/// Retain signed wire bytes, or null when nothing is published there yet.
Future<String?> getSignedWire(String url,
    {Duration timeout = const Duration(seconds: 30)}) async {
  final uri = updateUri(url);
  final client = HttpClient()..connectionTimeout = timeout;
  Future<String?> read() async {
    final request = await client.getUrl(uri);
    request.followRedirects = false;
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    final response = await request.close();
    if (response.statusCode == HttpStatus.notFound) {
      await response.drain<void>();
      return null;
    }
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

File _payloadFile() => File('${Directory.systemTemp.path}/flutter_patcher-'
    '${DateTime.now().microsecondsSinceEpoch}.fptc');

/// Downloads a signed payload of [size] bytes to a new temporary file for
/// native verification, which deletes it. Never more than [size] bytes, and
/// within two minutes.
Future<String> downloadPayload(
    String url, int size, void Function(int received) progress) async {
  final uri = updateUri(url);
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
  final file = _payloadFile();
  final sink = file.openWrite();
  try {
    await () async {
      final request = await client.getUrl(uri);
      request.followRedirects = false;
      final response = await request.close();
      // A compressed body's length is not the payload's; the size bound and
      // native digest check the decoded bytes.
      final identity =
          (response.headers.value(HttpHeaders.contentEncodingHeader) ??
                      'identity')
                  .toLowerCase() ==
              'identity';
      if (response.statusCode != 200 ||
          (identity &&
              response.contentLength != -1 &&
              response.contentLength != size)) {
        throw const PayloadDownloadException();
      }
      var received = 0;
      await for (final chunk
          in response.timeout(const Duration(seconds: 15))) {
        received += chunk.length;
        if (received > size) throw const PayloadDownloadException();
        sink.add(chunk);
        progress(received);
      }
      if (received != size) throw const PayloadDownloadException();
      await sink.flush();
    }()
        .timeout(const Duration(seconds: 120));
    await sink.close();
    return file.path;
  } catch (_) {
    await sink.close().catchError((_) {});
    await deletePayload(file.path);
    throw const PayloadDownloadException();
  } finally {
    client.close(force: true);
  }
}

/// A payload the app obtained itself, written for native verification.
Future<String> writePayload(List<int> bytes) async {
  final file = _payloadFile();
  await file.writeAsBytes(bytes, flush: true);
  return file.path;
}

Future<void> deletePayload(String path) async {
  try {
    await File(path).delete();
  } on FileSystemException {
    // Native verification already removed it.
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