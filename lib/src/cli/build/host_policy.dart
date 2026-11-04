import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import '../core.dart';
import '../project.dart';
import '../publish/protocol.dart';
import '../publish/trust.dart';

/// Public build inputs only. Native receives this policy inside the APK itself.
class HostPolicy {
  final Map<String, String> fields;
  HostPolicy(Map<String, String> values) : fields = Map.unmodifiable(values) {
    final expected = {
      ...TrustUpdate.scopeKeys.where((key) => key != 'fingerprint'),
      'schema',
      'fptc_key',
      'root_key',
      'keys',
    };
    if (fields.length != expected.length ||
        !fields.keys.every(expected.contains) ||
        fields['schema'] != '1' ||
        !{'bytecode', 'so'}.contains(fields['strategy'])) {
      throw const FormatException('Host policy fields/schema/strategy');
    }
    PublishManifest({
      for (final key in TrustUpdate.scopeKeys)
        key: key == 'fingerprint' ? '0' * 64 : fields[key]!,
      'schema': '1',
      'key_id': 'root',
      'revision': '1',
      'minPluginVersion': '0.0.0',
      'action': 'withdraw',
      'withdraw_through_seq': '1',
    });
    for (final name in ['fptc_key', 'root_key']) {
      final key = base64Decode(fields[name]!);
      if (key.length != 32 || base64Encode(key) != fields[name]) {
        throw const FormatException('Host public key encoding');
      }
    }
    TrustUpdate.parseKeys(fields['keys']!);
  }
  factory HostPolicy.parse(String text) {
    if (text.length > 16384) {
      throw const FormatException('Host policy too large');
    }
    final policy = HostPolicy((jsonDecode(text) as Map).cast<String, String>());
    if (text != policy.canonical) {
      throw const FormatException('Noncanonical host policy');
    }
    return policy;
  }
  String get canonical => jsonEncode({
    for (final key in fields.keys.toList()..sort()) key: fields[key],
  });
  String get digest => sha256.convert(utf8.encode(canonical)).toString();

  /// A policy file a developer wrote: any JSON layout, all values strings.
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
    return HostPolicy((value as Map).cast<String, String>());
  }

  /// The policy of a [project] built without one: the app identity and
  /// build number its build gets, the project's keys, and one channel.
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
    // The project's own mistakes first; keys come last.
    applicationId ??= await _applicationId(project, platform);
    versionCode ??= await buildNumber(project);
    final anchors = config.requireAnchors();
    return HostPolicy({
      'schema': '1',
      'strategy': strategy,
      'abi': platform == 'ios' ? 'ios-arm64' : 'arm64-v8a',
      'application_id': applicationId,
      'version_code': versionCode,
      'flavor': flavor ?? 'default',
      'channel': channel ?? 'production',
      'root_key': anchors.root,
      'fptc_key': anchors.patch,
      'keys': 'release:${anchors.publisher}',
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
