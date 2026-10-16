import 'dart:io';
import 'package:path/path.dart' as p;
import 'workspace.dart';

/// Dart sources under [root] that contain CRLF, as sorted POSIX paths.
///
/// Source identity is byte-exact: a CRLF checkout (Git for Windows defaults to
/// `core.autocrlf=true`) yields a different fingerprint than an LF checkout of
/// the same commit, and a patch built from the other line endings sees every
/// file as changed. Hashing is not normalized; callers warn instead.
Future<List<String>> crlfDartSources(String root) async {
  final found = <String>[];
  Future<void> visit(Directory directory) async {
    await for (final entry in directory.list(followLinks: false)) {
      final name = p.basename(entry.path);
      if (entry is Directory && !BuildWorkspace.excluded.contains(name)) {
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

String crlfWarning(List<String> files) =>
    '${files.length} Dart source(s) use CRLF line endings '
    '(${files.take(3).join(', ')}${files.length > 3 ? ', ...' : ''}). '
    'Patches must be built from a checkout with the same line endings, or '
    'every file counts as changed and native files fail with '
    'PATCH_NATIVE_CHANGE; add "* text=auto eol=lf" to .gitattributes or set '
    'core.autocrlf=false.';
