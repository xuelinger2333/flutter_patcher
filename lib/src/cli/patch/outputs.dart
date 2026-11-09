import 'dart:io';

import 'package:path/path.dart' as p;

import '../core.dart';
import '../../patch_file.dart';

/// What a finished output of `patch` is: a patch, or a withdrawal of its
/// host.
const outputStatuses = {'patch_created', 'withdrawal_created'};

/// Where `patch` writes [project]'s outputs, one directory each, named by
/// creation time; one still being written has a `.pending-` suffix.
String patchOutputsRoot(String project) =>
    p.join(project, '.dart_tool', 'flutter_patcher', 'patches');

/// The finished outputs `patch` wrote to [project], oldest first.
Future<List<String>> patchOutputs(String project) async {
  final root = Directory(patchOutputsRoot(project));
  if (!await root.exists()) return [];
  return (await root
        .list()
        .where(
          (e) =>
              e is Directory && RegExp(r'^\d+$').hasMatch(p.basename(e.path)),
        )
        .map((e) => e.path)
        .toList())
    ..sort();
}

/// The newest finished output `patch` wrote to [project].
Future<String?> latestPatchOutput(String project) async =>
    (await patchOutputs(project)).lastOrNull;

/// The newest output of one host and the file in it devices take.
class HostFile {
  const HostFile(this.output, this.file, {required this.signed});
  final String output;

  /// Null when the output has none: its host accepts only signed files and
  /// the machine that patched had no key.
  final String? file;
  final bool signed;
}

/// The newest output of each host [project] was patched for, by the name of
/// its files. A newer output of a host replaces an older one even when it
/// has no file: it never falls back to an older patch.
Future<Map<String, HostFile>> latestFiles(String project) async {
  final files = <String, HostFile>{};
  for (final output in await patchOutputs(project)) {
    final Map<String, dynamic> report;
    try {
      report = await readObject(p.join(output, 'patch.json'));
    } on Object {
      continue;
    }
    final scope = report['scope'], key = report['patch_key'];
    if (!outputStatuses.contains(report['status']) ||
        scope is! Map ||
        key is! String) {
      continue; // Not an output of this flutter_patcher.
    }
    final name = patchFileName(Map<String, String>.from(scope));
    final file = File(p.join(output, name));
    files[name] = HostFile(
      output,
      await file.exists() ? file.path : null,
      signed: key != '-',
    );
  }
  return files;
}
