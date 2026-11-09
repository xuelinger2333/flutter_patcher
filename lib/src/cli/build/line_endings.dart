import 'dart:io';

import 'package:path/path.dart' as p;

import 'workspace.dart';

/// Dart sources under [root] that contain CRLF, as sorted POSIX paths.
///
/// Source identity is byte-exact: a CRLF checkout (Git for Windows defaults to
/// `core.autocrlf=true`) yields a different fingerprint than an LF checkout of
/// the same commit, and a patch built from the other line endings sees every
/// file as changed. The baseline records them; patch explains a difference.
Future<List<String>> crlfDartSources(String root) async {
  final found = <String>[];
  Future<void> visit(Directory directory) async {
    await for (final entry in directory.list(followLinks: false)) {
      final name = p.basename(entry.path);
      if (entry is Directory &&
          !BuildWorkspace.skipped(
            p.relative(entry.path, from: root).replaceAll('\\', '/'),
          )) {
        await visit(entry);
      } else if (entry is File && name.endsWith('.dart')) {
        final bytes = await entry.readAsBytes();
        for (var i = 1; i < bytes.length; i++) {
          if (bytes[i] == 0x0a && bytes[i - 1] == 0x0d) {
            found.add(p.relative(entry.path, from: root).replaceAll('\\', '/'));
            break;
          }
        }
      }
    }
  }

  await visit(Directory(root));
  return found..sort();
}
