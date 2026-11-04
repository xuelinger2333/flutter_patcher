import 'dart:io';

import 'package:path/path.dart' as p;

import 'core.dart';

/// Work directories of one kind of run (`<cache>/builds/run`,
/// `<cache>/patches/run`), one per run. A run that succeeds removes its own;
/// a failed run leaves its directory (with `failure.json`) as evidence, and
/// only the newest [keepFailed] of those stay. A directory without either is
/// a run that never finished (a killed process); after [abandoned] it goes.
class RunWork {
  RunWork._();

  static const keepFailed = 3;
  static const abandoned = Duration(days: 1);

  /// Prunes [base]'s earlier runs, then creates this run's directory.
  static Future<String> create(String base) async {
    await prune(base);
    final work = temporaryName(base);
    await rejectLinks(work);
    await Directory(work).create(recursive: true);
    return work;
  }

  /// The run succeeded: its evidence is no longer needed. A file another
  /// process still holds leaves the rest to a later [prune].
  static Future<void> finish(String work) async {
    try {
      await Directory(work).deleteRetry(recursive: true);
    } on FileSystemException {
      // Abandoned without failure.json: pruned once it is old enough.
    }
  }

  static Future<void> prune(String base, {DateTime? now}) async {
    final parent = Directory(p.dirname(base));
    if (!await parent.exists()) return;
    final prefix = '${p.basename(base)}.pending-';
    final at = now ?? DateTime.now();
    final failed = <(DateTime, Directory)>[];
    await for (final entry in parent.list(followLinks: false)) {
      if (entry is! Directory || !p.basename(entry.path).startsWith(prefix)) {
        continue;
      }
      final marker = File(p.join(entry.path, 'failure.json'));
      if (await marker.exists()) {
        failed.add(((await marker.stat()).modified, entry));
      } else if (at.difference((await entry.stat()).modified) > abandoned) {
        await finish(entry.path);
      }
    }
    failed.sort((a, b) => b.$1.compareTo(a.$1));
    for (final (_, entry) in failed.skip(keepFailed)) {
      await finish(entry.path);
    }
  }
}
