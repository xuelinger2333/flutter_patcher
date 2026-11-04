import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import 'core.dart';
import 'keys/bundle.dart';

/// A project's `flutter_patcher.yaml`: what the commands use when no flag
/// gives it, so the usual workflow needs no flags. It holds nothing secret
/// and belongs in version control.
class ProjectConfig {
  ProjectConfig._(this.root, this._values);

  static const file = 'flutter_patcher.yaml';
  static const _known = {'store', 'baseline_store', 'trust', 'signing'};

  /// Written by `keys init` when the project has no configuration yet.
  static const template = '''
# flutter_patcher project settings. Commands read them when no flag is given.
# Nothing here is secret: commit this file.

# Where publish puts patches and the manifests devices read: file:// or s3://.
# Serve it from any HTTPS host; apps pass that URL to checkUpdate. Default:
# .flutter_patcher/updates in the project, which serve offers while developing.
# store: s3://my-bucket/patches

# Where host baselines are kept. Every patch of a host needs its baseline:
# keep it somewhere durable and backed up.
# baseline_store: s3://my-bucket/baselines

# Sign with an external command (a KMS, Vault, a password manager) instead of
# the key store or FLUTTER_PATCHER_KEYS. It reads the bytes to sign on stdin
# and prints a base64 Ed25519 signature; FLUTTER_PATCHER_SIGN_ROLE names the
# key (root, publisher or patch).
# signing:
#   command: my-signer --key "fp-\$FLUTTER_PATCHER_SIGN_ROLE"
''';

  final String root;
  final Map _values;

  String get path => p.join(root, file);

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
      for (final key in ['store', 'baseline_store']) {
        require(
          values[key] == null || values[key] is String,
          'CONFIG_INVALID',
          '$file: $key is a string.',
        );
      }
      bool strings(Object? map, Set<String> keys) =>
          map is Map &&
          map.keys.every(keys.contains) &&
          map.values.every((v) => v is String);
      require(
        values['trust'] == null ||
            (strings(values['trust'], {'root', 'publisher', 'patch'}) &&
                (values['trust'] as Map).length == 3),
        'CONFIG_INVALID',
        '$file: trust holds the root, publisher and patch public keys.',
      );
      require(
        values['signing'] == null || strings(values['signing'], {'command'}),
        'CONFIG_INVALID',
        '$file: signing holds a command.',
      );
    }
    return ProjectConfig._(project, values);
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

  /// The public keys this project's hosts trust, or null before keys init.
  TrustAnchors? get anchors {
    final trust = _values['trust'] as Map?;
    return trust == null
        ? null
        : TrustAnchors(
            root: trust['root'] as String,
            publisher: trust['publisher'] as String,
            patch: trust['patch'] as String,
          );
  }

  TrustAnchors requireAnchors() {
    final value = anchors;
    require(
      value != null,
      'KEYS_NOT_CONFIGURED',
      '$file has no trust keys; run `flutter_patcher keys init`, or '
          '`flutter_patcher keys import` with the project\'s key bundle.',
    );
    return value!;
  }

  /// The external signing command, when one is configured.
  String? get signingCommand =>
      (_values['signing'] as Map?)?['command'] as String?;

  /// Records [anchors] as this project's trust keys, creating the file from
  /// [template] if needed. The rest of an existing file is kept as written.
  Future<void> writeTrust(TrustAnchors anchors) async {
    require(
      this.anchors == null,
      'KEYS_ALREADY_CONFIGURED',
      '${ProjectConfig.file} already names this project\'s trust keys.',
    );
    final current = File(path);
    final text = await current.exists()
        ? await current.readAsString()
        : template;
    final separator = text.isEmpty || text.endsWith('\n') ? '' : '\n';
    await _write(
      '$text$separator\n'
      '# The public keys every host of this project trusts. Written by\n'
      '# `flutter_patcher keys`; hosts already shipped keep the keys they\n'
      '# were built with.\n'
      'trust:\n'
      '  root: ${anchors.root}\n'
      '  publisher: ${anchors.publisher}\n'
      '  patch: ${anchors.patch}\n',
    );
  }

  /// Replaces the publisher key after a rotation.
  Future<void> writePublisher(String publisher) async {
    final old = requireAnchors().publisher;
    final text = await File(path).readAsString();
    require(
      RegExp(RegExp.escape(old)).allMatches(text).length == 1,
      'CONFIG_INVALID',
      'Cannot find the publisher key in $file to replace it.',
    );
    await _write(text.replaceFirst(old, publisher));
  }

  Future<void> _write(String text) async {
    await rejectLinks(path);
    final staging = File(temporaryName(path));
    await staging.writeAsString(text, flush: true);
    await staging.renameRetry(path);
  }
}
