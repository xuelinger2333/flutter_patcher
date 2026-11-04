import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import 'core.dart';

/// A project's `flutter_patcher.yaml` and key directory: what the commands
/// use when no flag gives it, so the usual workflow needs no flags.
class ProjectConfig {
  ProjectConfig._(this.root, this.keys, this._values);

  static const file = 'flutter_patcher.yaml';
  static const defaultKeys = 'flutter_patcher_keys';
  static const _known = {'keys', 'store', 'baseline_store'};

  /// Written by `keys init` when the project has no configuration yet.
  static const template =
      '''
# flutter_patcher project settings. Commands read them when no flag is given.

# Where publish puts patches and the manifests devices read: file:// or s3://.
# Serve it from any HTTPS host; apps pass that URL to checkUpdate. Default:
# .flutter_patcher/updates in the project, which serve offers while developing.
# store: s3://my-bucket/patches

# Where host baselines are kept. Every patch of a host needs its baseline:
# keep it somewhere durable and backed up.
# baseline_store: s3://my-bucket/baselines

# Key directory written by keys init, relative to this file.
# keys: $defaultKeys
''';

  final String root, keys;
  final Map _values;

  static Future<ProjectConfig> load(String project) async {
    final path = p.join(project, file);
    await rejectLinks(path);
    var values = const {};
    if (await File(path).exists()) {
      final document = loadYaml(await File(path).readAsString());
      require(
        document == null || document is Map,
        'CONFIG_INVALID',
        '$file must be a map of settings.',
      );
      values = document as Map? ?? const {};
      final unknown = values.keys.where((key) => !_known.contains(key));
      require(
        unknown.isEmpty,
        'CONFIG_INVALID',
        'Unknown $file settings: ${unknown.join(', ')}',
      );
      require(
        values.values.every((value) => value is String),
        'CONFIG_INVALID',
        '$file settings are strings.',
      );
    }
    return ProjectConfig._(
      project,
      p.normalize(p.join(project, values['keys'] as String? ?? defaultKeys)),
      values,
    );
  }

  /// A setting, or null when it is not configured.
  String? operator [](String name) => _values[name] as String?;

  /// Publications live in the configured store, or in the project.
  String get store =>
      this['store'] ??
      Uri.directory(p.join(root, '.flutter_patcher', 'updates')).toString();

  /// Baselines live in the configured store, or in the project.
  String get baselineStore =>
      this['baseline_store'] ??
      Uri.directory(p.join(root, '.flutter_patcher', 'baselines')).toString();

  bool get baselinesInProject => this['baseline_store'] == null;

  /// The key file of [role] (`root`, `publisher` or `patch`).
  String key(String role, {bool private = false}) =>
      p.join(keys, role, private ? 'private-key.base64' : 'public-key.base64');

  Future<String> read(String role, {bool private = false}) async {
    final path = key(role, private: private);
    await rejectLinks(path);
    require(
      await File(path).exists(),
      'KEYS_MISSING',
      'Missing $path; run flutter_patcher keys init in the project.',
    );
    return (await File(path).readAsString()).trim();
  }
}
