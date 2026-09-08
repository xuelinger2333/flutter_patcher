import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';
import '../core.dart';

const baselineFiles = <String>[
  'app.dill',
  'dynamic_interface.yaml',
  'interface_detailed.json',
  'package_config.json',
  'source_hashes.json',
  'allocate_finalized.json',
  'libapp.so',
];
const buildBaselineFiles = ['compiler_interface.json', 'build_receipt.json'];
List<String> payloadFiles(Map<String, dynamic> m) =>
    [...baselineFiles, if (m['schema'] == 2) ...buildBaselineFiles];
final baselineHash = RegExp(r'^[0-9a-f]{64}$');
final _commit = RegExp(r'^[0-9a-f]{40}$');
final _version = RegExp(r'^\d+\.\d+\.\d+$');
List<String> manifestDifferences(
        Map<String, dynamic> a, Map<String, dynamic> b) =>
    [
      for (final k in {...a.keys, ...b.keys}.toList()..sort())
        if (canonical(a[k]) != canonical(b[k]))
          if (k == 'files' && a[k] is Map && b[k] is Map) ...[
            for (final name in {...baselineFiles, ...buildBaselineFiles})
              if (canonical(a[k][name]) != canonical(b[k][name])) 'files.$name'
          ] else
            k,
    ];
void valid(bool value, String message) =>
    require(value, 'BASELINE_INVALID', message);

String canonical(Object? value) {
  Object? sort(Object? v) {
    if (v is Map) {
      return {
        for (final k in v.keys.cast<String>().toList()..sort()) k: sort(v[k])
      };
    }
    if (v is List) return v.map(sort).toList();
    return v;
  }

  return '${jsonEncode(sort(value))}\n';
}

Future<Map<String, dynamic>> baselineObject(String path) async {
  try {
    valid(await File(path).length() <= 64 * 1024 * 1024,
        'Baseline JSON exceeds size limit.');
    final text = await File(path).readAsString();
    loadYaml(text);
    return jsonDecode(text) as Map<String, dynamic>;
  } catch (_) {
    throw Failure(
        'BASELINE_INVALID', 'Invalid JSON object: ${p.basename(path)}');
  }
}

/// v1 uses a domain prefix and four newline-delimited, constrained ASCII fields.
String fingerprint(
    String appHash, String engine, String interfaceHash, String flutter) {
  valid(
      baselineHash.hasMatch(appHash) &&
          baselineHash.hasMatch(interfaceHash) &&
          _commit.hasMatch(engine) &&
          _version.hasMatch(flutter),
      'Invalid fingerprint fields.');
  return sha256
      .convert(utf8.encode(
          'flutter-patcher-baseline-v1\n$appHash\n$engine\n$interfaceHash\n$flutter\n'))
      .toString();
}

void validateMetadata(Map<String, dynamic> m) {
  valid(
      m['schema'] is int &&
          [1, 2].contains(m['schema']) &&
          _version.hasMatch('${m['flutter_version']}') &&
          _commit.hasMatch('${m['engine_commit']}') &&
          RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')
              .hasMatch('${m['build_id']}'),
      'Invalid baseline schema/version/engine/build_id.');
  if (m['schema'] == 2) {
    valid(m['runtime_bootstrap'] is bool, 'Missing bootstrap status.');
  }
  final platform = m['platform'];
  valid(
      platform is Map &&
          platform['path'] ==
              'bin/cache/artifacts/engine/common/flutter_patched_sdk_product/platform_strong.dill' &&
          baselineHash.hasMatch('${platform['sha256']}'),
      'Invalid SDK-relative platform identity.');
}

Future<void> validateDetails(String root, String interfaceHash) async {
  final detail = await baselineObject(p.join(root, 'interface_detailed.json'));
  valid(
      detail['schema'] == 1 &&
          detail['interface_sha256'] == interfaceHash &&
          detail['entries'] is List,
      'Detailed interface does not match YAML.');
  final expected = <String>{};
  final yaml = loadYaml(
      await File(p.join(root, 'dynamic_interface.yaml')).readAsString());
  valid(yaml is Map, 'Interface must be a mapping.');
  const sections = [
    'extendable',
    'can-be-overridden',
    'can-be-used-as-type',
    'callable',
    'dynamically-callable'
  ];
  for (final section in (yaml as Map).keys) {
    valid(sections.contains(section) && yaml[section] is List,
        'Noncanonical interface section.');
    for (final row in yaml[section] as List) {
      valid(
          row is Map &&
              row['library'] is String &&
              row.keys
                  .every((k) => ['library', 'class', 'member'].contains(k)) &&
              row.values.every((v) => v is String),
          'Noncanonical interface row.');
      expected.add(canonical(
          {'section': section, ...Map<String, dynamic>.from(row as Map)}));
    }
  }
  final actual = <String>{};
  for (final row in detail['entries'] as List) {
    valid(
        row is Map &&
            row['sources'] is List &&
            (row['sources'] as List).isNotEmpty &&
            (row['sources'] as List).every((v) => [
                  'referenced',
                  'protocol',
                  'defaults',
                  'compiler-hint',
                  'platform-privates'
                ].contains(v)) &&
            row.containsKey('location'),
        'Invalid detailed interface entry.');
    final entry = Map<String, dynamic>.from(row as Map)
      ..remove('sources')
      ..remove('location');
    valid(actual.add(canonical(entry)), 'Duplicate detailed interface entry.');
  }
  valid(expected.length == actual.length && expected.containsAll(actual),
      'Detailed interface entries differ from YAML.');
}

Future<Map<String, dynamic>> createManifest(
    String root, Map<String, dynamic> metadata) async {
  validateMetadata(metadata);
  final files = <String, dynamic>{};
  var total = 0;
  for (final name in payloadFiles(metadata)) {
    final path = p.join(root, name);
    await rejectLinks(path);
    valid(await File(path).exists() && await File(path).length() > 0,
        'Missing/empty $name');
    total += await File(path).length();
    valid(total <= 1024 * 1024 * 1024, 'Baseline exceeds size limit.');
    files[name] = {
      'sha256': await hashFile(path),
      'size': await File(path).length()
    };
  }
  await validateDetails(
      root, files['dynamic_interface.yaml']['sha256'] as String);
  if (metadata['schema'] == 2) {
    final compiler =
        await baselineObject(p.join(root, 'compiler_interface.json'));
    valid(
        compiler.isNotEmpty &&
            compiler.values.every((v) =>
                v is List &&
                v.every((r) => r is Map && r.values.every((x) => x is String))),
        'Malformed compiler interface dump.');
    final receipt = await baselineObject(p.join(root, 'build_receipt.json'));
    valid(
        receipt['runtime_bootstrap'] == metadata['runtime_bootstrap'] &&
            receipt['fingerprint'] ==
                fingerprint(
                    files['app.dill']['sha256'] as String,
                    metadata['engine_commit'] as String,
                    files['dynamic_interface.yaml']['sha256'] as String,
                    metadata['flutter_version'] as String) &&
            receipt['app_only'] == true &&
            receipt['interface_sha256'] ==
                files['dynamic_interface.yaml']['sha256'] &&
            receipt['libapp_sha256'] == files['libapp.so']['sha256'] &&
            baselineHash.hasMatch('${receipt['apk_sha256']}'),
        'Build receipt binding differs.');
  }
  final packages = await baselineObject(p.join(root, 'package_config.json'));
  valid(packages['configVersion'] == 2 && packages['packages'] is List,
      'Invalid package configuration.');
  final sources = await baselineObject(p.join(root, 'source_hashes.json'));
  valid(
      sources['schema'] == 1 &&
          sources['files'] is Map &&
          (sources['files'] as Map).isNotEmpty,
      'Source hashes are required.');
  for (final entry in (sources['files'] as Map).entries) {
    valid(
        entry.key is String &&
            RegExp(r'^package:[A-Za-z_][A-Za-z_0-9]*/[^\\]+$')
                .hasMatch(entry.key as String) &&
            !(entry.key as String)
                .split('/')
                .any((s) => s == '..' || s == '.' || s.isEmpty) &&
            baselineHash.hasMatch('${entry.value}'),
        'Invalid logical source identity/hash.');
  }
  final allocated =
      await baselineObject(p.join(root, 'allocate_finalized.json'));
  valid(allocated['schema'] == 1 && allocated['classes'] is List,
      'Allocation class set is required.');
  final classes = allocated['classes'] as List;
  valid(
      classes.every((v) =>
              v is String &&
              RegExp(r'^(package:|dart:).+::[^:]+$').hasMatch(v)) &&
          classes.toSet().length == classes.length,
      'Invalid/duplicate allocation class identity.');
  return {
    'schema': metadata['schema'],
    if (metadata['schema'] == 2)
      'runtime_bootstrap': metadata['runtime_bootstrap'],
    'flutter_version': metadata['flutter_version'],
    'engine_commit': metadata['engine_commit'],
    'build_id': metadata['build_id'],
    'platform': metadata['platform'],
    'files': files,
    'fingerprint': fingerprint(
        files['app.dill']['sha256'] as String,
        metadata['engine_commit'] as String,
        files['dynamic_interface.yaml']['sha256'] as String,
        metadata['flutter_version'] as String)
  };
}

Future<Map<String, dynamic>> verifyBaseline(String root,
    {String? expected, String? sdkRoot}) async {
  await rejectLinks(root);
  final manifest = await baselineObject(p.join(root, 'baseline.manifest.json'));
  final computed = await createManifest(root, manifest);
  valid(canonical(manifest) == canonical(computed),
      'Baseline manifest/files do not agree.');
  require(
      expected == null || computed['fingerprint'] == expected,
      'BASELINE_FINGERPRINT_MISMATCH',
      'Requested fingerprint differs from baseline.');
  if (sdkRoot != null) await verifyPlatform(computed, sdkRoot);
  return computed;
}

Future<void> verifyPlatform(
    Map<String, dynamic> metadata, String sdkRoot) async {
  validateMetadata(metadata);
  final platform = Map<String, dynamic>.from(metadata['platform'] as Map);
  final file = p.join(sdkRoot, platform['path'] as String);
  valid(await File(file).exists() && await hashFile(file) == platform['sha256'],
      'Selected SDK platform hash differs.');
  valid(
      (await File(p.join(sdkRoot, 'bin/internal/engine.version'))
                  .readAsString())
              .trim() ==
          metadata['engine_commit'],
      'Selected SDK engine differs.');
}
