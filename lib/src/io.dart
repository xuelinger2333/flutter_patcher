import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

bool get isAndroid => Platform.isAndroid;

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

Future<Map<String, dynamic>> getJson(
  String url, {
  Map<String, String>? headers,
  Duration timeout = const Duration(seconds: 10),
}) async {
  final uri = Uri.parse(url);
  final client = HttpClient()..connectionTimeout = timeout;
  try {
    final req = await client.getUrl(uri).timeout(timeout);
    headers?.forEach(req.headers.set);
    req.headers.set(HttpHeaders.acceptHeader, 'application/json');
    final resp = await req.close().timeout(timeout);
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw Exception('HTTP ${resp.statusCode}');
    }
    final body = await resp.transform(utf8.decoder).join();
    final decoded = jsonDecode(body);
    if (decoded is! Map) {
      throw Exception('Invalid JSON: expected object');
    }
    return Map<String, dynamic>.from(decoded);
  } finally {
    client.close(force: true);
  }
}

Future<String> stagePatchBytes(String dir, Uint8List bytes) async {
  final staged = File(
    '$dir/flutter_patcher_staged_${DateTime.now().microsecondsSinceEpoch}.so',
  );
  await staged.writeAsBytes(bytes, flush: true);
  return staged.path;
}

Future<void> deleteFileIfExists(String path) async {
  final file = File(path);
  if (await file.exists()) {
    await file.delete();
  }
}
