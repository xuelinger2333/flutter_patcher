import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import '../core.dart';
import '../project.dart';

/// Release ABI → platform. Each is a separate release slot; iOS hosts load
/// bytecode only, because iOS code signing forbids replacing machine code.
const platformOfAbi = {'arm64-v8a': 'android', 'ios-arm64': 'ios'};

/// What names a host build: its policy fields and its compile fingerprint.
const scopeKeys = {
  'application_id',
  'channel',
  'flavor',
  'version_code',
  'abi',
  'fingerprint',
  'strategy',
};

/// Public build inputs only, policy schema 2: the build a host is and the
/// patch key it trusts (`fptc_key`, or `-` for unsigned patch files).
/// Native receives this policy inside the APK or Info.plist itself.
class HostPolicy {
  final Map<String, String> fields;
  HostPolicy(Map<String, String> values) : fields = Map.unmodifiable(values) {
    void check(bool valid, String reason) {
      if (!valid) throw FormatException('Host policy: $reason');
    }

    bool matches(String key, String pattern) =>
        RegExp('^(?:$pattern)\$').hasMatch(fields[key] ?? '');
    final expected = {
      ...scopeKeys.where((key) => key != 'fingerprint'),
      'schema',
      'fptc_key',
    };
    check(
      fields.length == expected.length && fields.keys.every(expected.contains),
      'fields',
    );
    check(fields['schema'] == '2', 'schema');
    check({'bytecode', 'so'}.contains(fields['strategy']), 'strategy');
    check(platformOfAbi.containsKey(fields['abi']), 'abi');
    check(
      platformOfAbi[fields['abi']] != 'ios' || fields['strategy'] == 'bytecode',
      'iOS hosts load bytecode only',
    );
    check(
      matches(
        'application_id',
        r'[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+',
      ),
      'application_id',
    );
    check(
      matches('channel', r'[A-Za-z0-9_]{1,64}') &&
          matches('flavor', r'[A-Za-z0-9_]{1,64}'),
      'flavor and channel take letters, digits and _ only',
    );
    check(
      matches('version_code', r'[1-9][0-9]{0,9}') &&
          int.parse(fields['version_code']!) <= 2100000000,
      'version_code',
    );
    final key = fields['fptc_key']!;
    if (key != '-') {
      try {
        final raw = base64Decode(key);
        check(raw.length == 32 && base64Encode(raw) == key, 'fptc_key');
      } on FormatException {
        check(false, 'fptc_key');
      }
    }
  }

  /// A stored policy, as `build` recorded it in a baseline.
  factory HostPolicy.parse(String text) {
    if (text.length > 16384) {
      throw const FormatException('Host policy too large');
    }
    final value = (jsonDecode(text) as Map).cast<String, String>();
    require(
      value['schema'] != '1',
      'PATCH_BASELINE_INCOMPATIBLE',
      'This host was built with flutter_patcher 1.0; patch and publish for '
          'it with flutter_patcher 1.0.0+1.',
    );
    final policy = HostPolicy(value);
    if (text != policy.canonical) {
      throw const FormatException('Noncanonical host policy');
    }
    return policy;
  }
  String get canonical => jsonEncode({
    for (final key in fields.keys.toList()..sort()) key: fields[key],
  });
  String get digest => sha256.convert(utf8.encode(canonical)).toString();

  /// Whether hosts of this policy accept only files signed by [patchKey].
  bool get signed => fields['fptc_key'] != '-';
  String get patchKey => fields['fptc_key']!;

  /// A policy file a developer wrote: any JSON layout, all values strings.
  /// A flutter_patcher 1.0 policy (schema 1) keeps its patch key; its root
  /// and publisher keys are not used any more.
  factory HostPolicy.read(String text) {
    require(
      text.length <= 16384,
      'BUILD_CONFIG_INVALID',
      'Host policy too large',
    );
    final value = jsonDecode(text);
    require(
      value is Map && value.values.every((v) => v is String),
      'BUILD_CONFIG_INVALID',
      'A host policy is a JSON object of strings.',
    );
    final fields = (value as Map).cast<String, String>();
    try {
      return HostPolicy(
        fields['schema'] == '1'
            ? ({...fields}
                ..remove('root_key')
                ..remove('keys')
                ..['schema'] = '2')
            : fields,
      );
    } on FormatException catch (error) {
      throw Failure('BUILD_CONFIG_INVALID', error.message);
    }
  }

  /// The policy of a [project] built without one: the app identity and
  /// build number its build gets, the project's patch key if it has one,
  /// and one channel.
  static Future<HostPolicy> of(
    String project,
    ProjectConfig config, {
    required String platform,
    String? applicationId,
    String? versionCode,
    String? flavor,
    String? channel,
    String? strategy,
  }) async {
    strategy ??= 'bytecode';
    require(
      platform == 'android' || strategy == 'bytecode',
      'BUILD_CONFIG_INVALID',
      'An iOS host is a bytecode host.',
    );
    for (final (option, value) in [('flavor', flavor), ('channel', channel)]) {
      require(
        value == null || RegExp(r'^[A-Za-z0-9_]{1,64}$').hasMatch(value),
        'BUILD_CONFIG_INVALID',
        '--$option takes 1 to 64 letters, digits and _, not $value: it '
            'names the host\'s patch files.',
      );
    }
    applicationId ??= await _applicationId(project, platform);
    versionCode ??= await buildNumber(project);
    return HostPolicy({
      'schema': '2',
      'strategy': strategy,
      'abi': platform == 'ios' ? 'ios-arm64' : 'arm64-v8a',
      'application_id': applicationId,
      'version_code': versionCode,
      'flavor': flavor ?? 'default',
      'channel': channel ?? 'production',
      'fptc_key': config.patchKey ?? '-',
    });
  }
}

/// The build number of [project]'s pubspec version (`1.2.0+7` is 7): the
/// versionCode and CFBundleVersion Flutter builds it with.
Future<String> buildNumber(String project) async {
  final pubspec = loadYaml(
    await File(p.join(project, 'pubspec.yaml')).readAsString(),
  ) as Map;
  final match = RegExp(r'^[^+]+\+([1-9][0-9]*)$')
      .firstMatch('${pubspec['version']}');
  require(
    match != null,
    'BUILD_CONFIG_INVALID',
    'Give pubspec.yaml a build number (version: 1.0.0+1), or pass --version-code.',
  );
  return match!.group(1)!;
}

/// The one application id [project]'s Gradle or Xcode project declares.
Future<String> _applicationId(String project, String platform) async {
  final ids = <String>{};
  if (platform == 'android') {
    for (final name in ['build.gradle.kts', 'build.gradle']) {
      final file = File(p.join(project, 'android', 'app', name));
      if (!await file.exists()) continue;
      for (final match in RegExp(
        r'''applicationId\s*=?\s*["']([^"'$]+)["']''',
      ).allMatches(await file.readAsString())) {
        ids.add(match.group(1)!);
      }
    }
  } else {
    final file = File(
      p.join(project, 'ios', 'Runner.xcodeproj', 'project.pbxproj'),
    );
    if (await file.exists()) {
      for (final match in RegExp(
        r'PRODUCT_BUNDLE_IDENTIFIER = "?([^";$]+)"?;',
      ).allMatches(await file.readAsString())) {
        if (!match.group(1)!.endsWith('.RunnerTests')) ids.add(match.group(1)!);
      }
    }
  }
  require(
    ids.length == 1,
    'BUILD_CONFIG_INVALID',
    ids.isEmpty
        ? 'Cannot find the application id; pass --application-id.'
        : 'The project declares several application ids (${ids.join(', ')}); pass --application-id.',
  );
  return ids.single;
}
