import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

bool get isAndroid => Platform.isAndroid;

String get operatingSystem => Platform.operatingSystem;

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
