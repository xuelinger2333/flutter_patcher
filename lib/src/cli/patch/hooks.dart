import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../core.dart';

/// Runs [action] (the patch's `flutter build bundle`) with every package that
/// has build hooks replaced by a copy without its `hook/` directory.
///
/// Flutter runs a package's hooks whenever `hook/build.dart` exists, and the
/// hooks need the target toolchain (xcrun, the NDK) that a developer host may
/// lack. Their output is native code, which a patch never carries: `hook/` is
/// a native input, so it matches the host's. Every host takes this path, so
/// the bundle step behaves the same on Linux, macOS and Windows.
Future<T> withoutBuildHooks<T>(
  String packageConfig,
  String shadowRoot,
  Future<T> Function() action,
) async {
  final file = File(packageConfig);
  final original = await file.readAsBytes();
  final config = jsonDecode(utf8.decode(original)) as Map<String, dynamic>;
  final base = file.parent.uri;
  var changed = false;
  for (final row in (config['packages'] as List).cast<Map<String, dynamic>>()) {
    final root = base.resolve(
      (row['rootUri'] as String).endsWith('/')
          ? row['rootUri'] as String
          : '${row['rootUri']}/',
    );
    final hook = Directory.fromUri(root.resolve('hook/'));
    if (!await hook.exists()) continue;
    final shadow = Directory(p.join(shadowRoot, row['name'] as String));
    require(
      !await shadow.exists(),
      'PATCH_SOURCE_INVALID',
      'Duplicate package ${row['name']}',
    );
    await _copyWithoutHooks(Directory.fromUri(root), shadow, hook.path);
    row['rootUri'] = shadow.uri.toString();
    changed = true;
  }
  if (!changed) return action();
  await file.writeAsString(jsonEncode(config));
  try {
    return await action();
  } finally {
    await file.writeAsBytes(original);
  }
}

Future<void> _copyWithoutHooks(
  Directory from,
  Directory to,
  String hook,
) async {
  await to.create(recursive: true);
  await for (final entry in from.list(followLinks: false)) {
    if (p.equals(entry.path, hook) || p.basename(entry.path) == '.dart_tool') {
      continue;
    }
    final target = p.join(to.path, p.basename(entry.path));
    if (entry is Directory) {
      await _copyWithoutHooks(entry, Directory(target), hook);
    } else if (entry is File) {
      await entry.copy(target);
    } else {
      throw Failure(
        'PATCH_SOURCE_INVALID',
        'Package contains a link: ${entry.path}',
      );
    }
  }
}
