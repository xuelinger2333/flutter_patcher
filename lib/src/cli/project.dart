import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import 'core.dart';
import 'crypto/ed25519.dart';

/// A project's `flutter_patcher.yaml`: what the commands use when no flag
/// gives it, so the usual workflow needs no flags. It holds nothing secret
/// and belongs in version control.
class ProjectConfig {
  ProjectConfig._(this.root, this._values);

  static const file = 'flutter_patcher.yaml';
  static const _known = {'url', 'store', 'baseline_store', 'trust', 'signing'};

  /// Where serve offers patches, and where hosts look when url is not set.
  static const localUrl = 'http://127.0.0.1:8686';

  /// Written by `init` when the project has no configuration yet.
  static const template = '''
# flutter_patcher project settings. Commands read them when no flag is given.
# Every setting is optional, and nothing here is secret.

# The address FlutterPatcher.checkUpdate() uses when the app passes none;
# build writes it into the app. Default: http://127.0.0.1:8686, where serve
# offers patches while developing.
# url: https://cdn.example.com/my-app

# Where publish writes patch files: file:// or s3://. Default:
# .flutter_patcher/updates in the project.
# store: s3://my-bucket/patches

# Where host baselines are kept. Every patch of a host needs its baseline:
# keep it somewhere durable and backed up.
# baseline_store: s3://my-bucket/baselines

# Sign with an external command (a KMS, Vault, a password manager) instead of
# the key store or FLUTTER_PATCHER_KEYS. It reads the bytes to sign on stdin
# and prints a base64 Ed25519 signature; FLUTTER_PATCHER_SIGN_ROLE is patch.
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
      for (final key in ['url', 'store', 'baseline_store']) {
        require(
          values[key] == null || values[key] is String,
          'CONFIG_INVALID',
          '$file: $key is a string.',
        );
      }
      final url = Uri.tryParse(values['url'] as String? ?? localUrl);
      require(
        url != null &&
            // Devices take plain HTTP only from themselves (serve, adb reverse).
            (url.scheme == 'https' ||
                (url.scheme == 'http' &&
                    const {
                      '127.0.0.1',
                      'localhost',
                      '::1',
                    }.contains(url.host))) &&
            url.host.isNotEmpty &&
            !url.hasQuery &&
            !url.hasFragment,
        'CONFIG_INVALID',
        '$file: url is an https:// address (http only for 127.0.0.1), such as '
            'https://cdn.example.com/my-app.',
      );
      bool strings(Object? map, Set<String> keys) =>
          map is Map &&
          map.keys.every(keys.contains) &&
          map.values.every((v) => v is String);
      // flutter_patcher 1.0 also wrote root and publisher keys; only the
      // patch key is used.
      final trust = values['trust'];
      require(
        trust == null ||
            (trust is Map &&
                trust.keys.every(
                  {'root', 'publisher', 'patch', 'enabled'}.contains,
                ) &&
                rawEd25519Key(trust['patch']) != null &&
                ['root', 'publisher'].every(
                  (role) => trust[role] == null || trust[role] is String,
                ) &&
                (trust['enabled'] == null || trust['enabled'] is bool)),
        'CONFIG_INVALID',
        '$file: trust.patch is the base64 Ed25519 public key of the patch key, '
            'and trust.enabled is true or false.',
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

  /// Where hosts download patches: the configured url, or serve's address.
  String get url => (this['url'] ?? localUrl).replaceFirst(RegExp(r'/+$'), '');

  bool get urlIsLocal => this['url'] == null;

  /// Publications live in the configured store, or in the project.
  String get store =>
      this['store'] ??
      Uri.directory(p.join(root, '.flutter_patcher', 'updates')).toString();

  /// Baselines live in the configured store, or in the project.
  String get baselineStore =>
      this['baseline_store'] ??
      Uri.directory(p.join(root, '.flutter_patcher', 'baselines')).toString();

  bool get baselinesInProject => this['baseline_store'] == null;

  /// The project's patch public key, or null before `init` creates one.
  String? get patchKey => (_values['trust'] as Map?)?['patch'] as String?;

  /// Whether hosts built now are signed: `trust.enabled`. A file that names
  /// a key without it, as flutter_patcher 1.0 wrote, counts as true, since
  /// its hosts always were signed.
  bool get signingEnabled =>
      patchKey != null && (_values['trust'] as Map)['enabled'] != false;

  /// The key hosts built now accept patch files from, or null for an
  /// unsigned host.
  String? get hostKey => signingEnabled ? patchKey : null;

  /// The external signing command, when one is configured.
  String? get signingCommand =>
      (_values['signing'] as Map?)?['command'] as String?;

  /// Records [patchKey] as the project's patch key, with signing off, in a
  /// project that names none yet, creating the file from [template] if
  /// needed. The rest of an existing file is kept as written.
  Future<void> writeTrust(String patchKey) async {
    final current = File(path);
    final text = await current.exists()
        ? await current.readAsString()
        : template;
    final separator = text.isEmpty || text.endsWith('\n') ? '' : '\n';
    await _write(
      '$text$separator\n'
      '# The project\'s patch key, written by `flutter_patcher init`. Its\n'
      '# private key is in the key store of the computer that ran init.\n'
      'trust:\n'
      '  patch: $patchKey\n'
      '  # true: hosts built from now on accept only patch files signed by\n'
      '  # this key. Hosts already shipped keep what they were built with.\n'
      '  enabled: false\n',
    );
  }

  /// Creates the file from [template] when the project has none; true when
  /// it did.
  Future<bool> create() async {
    if (await File(path).exists()) return false;
    await _write(template);
    return true;
  }

  Future<void> _write(String text) async {
    await rejectLinks(path);
    final staging = File(temporaryName(path));
    await staging.writeAsString(text, flush: true);
    await staging.renameRetry(path);
  }
}
