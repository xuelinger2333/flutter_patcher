import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:path/path.dart' as p;
import '../core.dart';
import 'manifest.dart';

/// Strict flat ustar subset: only the seven payload files and the manifest.
/// No links, directories, extensions, traversal, duplicate or unlisted entries.
class BaselineArchive {
  final String zstd;
  final int maxBytes;
  BaselineArchive({this.zstd = 'zstd', this.maxBytes = 1024 * 1024 * 1024});
  static final names = [
    ...baselineFiles,
    ...buildBaselineFiles,
    'host_policy.json',
    'baseline.manifest.json'
  ]..sort();

  Future<void> codec(String input, String output, {bool decode = false}) async {
    await rejectLinks(output);
    valid(!await File(output).exists(), 'Archive output already exists.');
    Process process;
    try {
      process = await Process.start(
          zstd, ['-q', if (decode) '-d', '-c', '--', input]);
    } on ProcessException {
      throw Failure(
          'BASELINE_CODEC_MISSING', 'Install zstd on the Linux build host.');
    }
    final sink = File(output).openWrite();
    final errors = process.stderr.drain<void>();
    var count = 0;
    try {
      await for (final chunk
          in process.stdout.timeout(const Duration(seconds: 60))) {
        count += chunk.length;
        valid(count <= maxBytes, 'Archive exceeds the configured size limit.');
        sink.add(chunk);
      }
      await sink.flush();
      valid(await process.exitCode.timeout(const Duration(seconds: 60)) == 0,
          'Invalid zstd stream or codec failure.');
    } finally {
      process.kill();
      await sink.close();
      await errors;
    }
  }

  Future<void> pack(String root, String output) async {
    final manifest = await verifyBaseline(root);
    final raw = '$output.tar';
    await rejectLinks(raw);
    valid(!await File(raw).exists(), 'Archive staging already exists.');
    final sink = File(raw).openWrite();
    var total = 1024;
    try {
      for (final name in [...payloadFiles(manifest), 'baseline.manifest.json']
        ..sort()) {
        final file = File(p.join(root, name));
        final size = await file.length();
        total += 512 + ((size + 511) ~/ 512) * 512;
        valid(total <= maxBytes, 'Baseline exceeds archive size limit.');
        final h = Uint8List(512);
        void field(int start, int length, String text) {
          final bytes = ascii.encode(text);
          valid(bytes.length <= length, 'Tar field overflow.');
          h.setRange(start, start + bytes.length, bytes);
        }

        void octal(int start, int width, int n) => field(start, width,
            '${n.toRadixString(8).padLeft(width - 1, '0')}\u0000');
        field(0, 100, name);
        octal(100, 8, 420);
        octal(108, 8, 0);
        octal(116, 8, 0);
        octal(124, 12, size);
        octal(136, 12, 0);
        h.fillRange(148, 156, 32);
        h[156] = 48;
        field(257, 6, 'ustar\u0000');
        field(263, 2, '00');
        field(148, 8,
            '${h.fold<int>(0, (a, b) => a + b).toRadixString(8).padLeft(6, '0')}\u0000 ');
        sink.add(h);
        await sink.addStream(file.openRead());
        sink.add(Uint8List((512 - size % 512) % 512));
      }
      sink.add(Uint8List(1024));
      await sink.flush();
    } finally {
      await sink.close();
    }
    await codec(raw, output);
  }

  Future<void> unpack(String archive, String output) async {
    await rejectLinks(output);
    valid(
        !await FileSystemEntity.isDirectory(output) &&
            !await File(output).exists(),
        'Extraction target already exists.');
    valid(await File(archive).length() <= maxBytes,
        'Compressed archive exceeds limit.');
    final raw = temporaryName('$archive.decoded.tar');
    await codec(archive, raw, decode: true);
    await Directory(output).create(recursive: true);
    final input = await File(raw).open();
    final seen = <String>{};
    try {
      while (true) {
        final h = await input.read(512);
        valid(h.length == 512, 'Truncated tar header.');
        if (h.every((b) => b == 0)) {
          final second = await input.read(512);
          valid(second.length == 512 && second.every((b) => b == 0),
              'Missing tar end markers.');
          while (await input.position() < await input.length()) {
            valid((await input.read(8192)).every((b) => b == 0),
                'Trailing data after tar end.');
          }
          break;
        }
        String field(int start, int end) => ascii
            .decode(h.sublist(start, end).takeWhile((b) => b != 0).toList());
        int octal(int start, int end) {
          final text = field(start, end).trim();
          valid(
              RegExp(r'^[0-7]+$').hasMatch(text), 'Invalid tar numeric field.');
          return int.parse(text, radix: 8);
        }

        final sum = octal(148, 156);
        final checksum = h.fold<int>(0, (a, b) => a + b) -
            h.sublist(148, 156).fold<int>(0, (a, b) => a + b) +
            8 * 32;
        valid(sum == checksum, 'Tar header checksum mismatch.');
        final name = field(0, 100);
        valid(
            names.contains(name) &&
                seen.add(name) &&
                (h[156] == 48 || h[156] == 0) &&
                field(157, 257).isEmpty &&
                field(345, 500).isEmpty &&
                field(257, 263) == 'ustar',
            'Unsafe, duplicate or unknown tar entry: $name');
        final size = octal(124, 136);
        valid(
            size > 0 &&
                size <= maxBytes &&
                await input.position() + size <= await input.length(),
            'Invalid tar payload length.');
        final sink = File(p.join(output, name)).openWrite();
        try {
          var remaining = size;
          while (remaining > 0) {
            final bytes =
                await input.read(remaining > 65536 ? 65536 : remaining);
            valid(bytes.isNotEmpty, 'Truncated tar payload.');
            sink.add(bytes);
            remaining -= bytes.length;
          }
          await sink.flush();
        } finally {
          await sink.close();
        }
        final pad = await input.read((512 - size % 512) % 512);
        valid(
            pad.length == (512 - size % 512) % 512 && pad.every((b) => b == 0),
            'Invalid tar padding.');
      }
      valid(seen.containsAll([...baselineFiles, 'baseline.manifest.json']),
          'Missing baseline archive entries.');
    } on Failure {
      rethrow;
    } catch (_) {
      throw Failure('BASELINE_INVALID', 'Malformed baseline archive.');
    } finally {
      await input.close();
    }
    final manifest = await verifyBaseline(output);
    valid(seen.length == payloadFiles(manifest).length + 1,
        'Unexpected baseline schema entries.');
  }
}
