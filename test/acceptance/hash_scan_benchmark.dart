// Diagnostic experiment, not a production integrity implementation.
// Run as an AOT executable with a valid .fptc path. Host timings are not Android timings.
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter_patcher/src/bootstrap/patch_archive.dart';

class _Result implements Sink<Digest> {
  late Digest value;
  void add(Digest data) => value = data;
  void close() {}
}

void main(List<String> args) {
  final bytes = File(args.single).readAsBytesSync();
  final module =
      readPatchArchive(Uint8List.sublistView(bytes, 146))['module.bc']!;
  final start = module.offsetInBytes - bytes.offsetInBytes;
  final ranges = [
    (0, bytes.length),
    (146, bytes.length),
    (start, start + module.length)
  ];
  List<String> sequential() => [
        for (final r in ranges)
          sha256.convert(Uint8List.sublistView(bytes, r.$1, r.$2)).toString()
      ];
  List<String> interleaved() {
    final results = List.generate(ranges.length, (_) => _Result());
    final sinks = [for (final r in results) sha256.startChunkedConversion(r)];
    for (var pos = 0; pos < bytes.length; pos += 32768) {
      final end = min(pos + 32768, bytes.length);
      for (var i = 0; i < ranges.length; i++) {
        final lo = max(pos, ranges[i].$1), hi = min(end, ranges[i].$2);
        if (lo < hi) sinks[i].add(Uint8List.sublistView(bytes, lo, hi));
      }
    }
    for (final sink in sinks) {
      sink.close();
    }
    return [for (final result in results) result.value.toString()];
  }

  final expected = sequential();
  final samples = <String, List<int>>{'sequential': [], 'interleaved': []};
  for (var round = 0; round < 16; round++) {
    for (final name
        in round.isEven ? samples.keys : samples.keys.toList().reversed) {
      final watch = Stopwatch()..start();
      final result = name == 'sequential' ? sequential() : interleaved();
      final elapsed = watch.elapsedMicroseconds;
      if (jsonEncode(result) != jsonEncode(expected))
        throw StateError('Digest mismatch');
      if (round >= 4) samples[name]!.add(elapsed);
    }
  }
  print(jsonEncode({
    'scope': 'host_aot_hash_scan_experiment',
    'file_bytes': bytes.length,
    'digests': expected,
    'samples_us': samples
  }));
}
