import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';
import '../core.dart';
import 'sources.dart';

/// Names exported by a carried library must be hidden from the host barrel.
/// The partition metadata intentionally records the declarations used for the
/// static closure, but a Dart library may also export public typedefs (for
/// example ExpansionTileController) that are not class declarations.  Scan
/// the source for all public top-level type declarations so the generated
/// barrel cannot expose two definitions of the same name.
Set<String> _publicTypeDeclarations(String source) {
  final names = <String>{};
  final pattern = RegExp(
      r'^\s*(?:(?:abstract|base|interface|final|sealed)\s+)*(?:class|enum|mixin|extension\s+type)\s+([A-Za-z_]\w*)',
      multiLine: true);
  for (final match in pattern.allMatches(source)) {
    final name = match.group(1)!;
    if (!name.startsWith('_')) names.add(name);
  }
  final typedefPattern =
      RegExp(r'^\s*typedef\s+([A-Za-z_]\w*)', multiLine: true);
  for (final match in typedefPattern.allMatches(source)) {
    final name = match.group(1)!;
    if (!name.startsWith('_')) names.add(name);
  }
  return names;
}

/// Resolves relative imports from a copied framework source file. The SDK
/// sources predominantly use relative imports; once a file moves under the
/// isolated carry package those imports must point either to another copied
/// library or back to the host's package:flutter library.
Map<String, String> _relativeFrameworkRewrites({
  required String relative,
  required String packageName,
  required Set<String> carry,
  required String source,
}) {
  final rewrites = <String, String>{};
  final base = Uri.parse('package:flutter/$relative');
  final directives = RegExp(r'''\b(?:import|export)\s+['"]([^'"]+)['"]''');
  for (final match in directives.allMatches(source)) {
    final value = match.group(1)!;
    // Dart accepts both `foo.dart` and `../foo.dart` for relative imports.
    // Keep absolute package/dart URIs untouched.
    if (value.contains(':')) continue;
    final resolved = base.resolve(value).toString();
    if (!resolved.startsWith('package:flutter/')) continue;
    if (carry.contains(resolved)) {
      rewrites[value] = resolved.replaceFirst(
          'package:flutter/', 'package:$packageName/');
    } else {
      rewrites[value] = resolved;
    }
  }
  return rewrites;
}

/// Materialises only the framework libraries selected by a partition. The
/// package is isolated under the patch sequence so the host's package:flutter
/// libraries remain available for normal imports.
Future<Map<String, Object?>> prepareFrameworkCarry({
  required String partition,
  required String sdkRoot,
  required String destination,
  required String packagesConfig,
  required int seq,
  Set<String>? selected,
}) async {
  final decoded = loadYaml(await File(partition).readAsString());
  if (decoded is! Map || decoded['schema'] != 1 || decoded['carry'] is! List) {
    throw Failure(
        'FRAMEWORK_PARTITION_MISMATCH', 'Invalid framework partition metadata');
  }
  final partitionCarry = (decoded['carry'] as List).cast<String>().toSet();
  final carry = selected ?? partitionCarry;
  if (!partitionCarry.containsAll(carry)) {
    throw Failure('FRAMEWORK_PARTITION_MISMATCH',
        'Selected carry set is not contained in the partition');
  }
  final libraries = decoded['libraries'] is List
      ? (decoded['libraries'] as List)
          .whereType<Map>()
          .map((row) => Map<String, dynamic>.from(row))
          .toList()
      : const <Map<String, dynamic>>[];
  if (carry.any((uri) => !uri.startsWith('package:flutter/'))) {
    throw Failure(
        'FRAMEWORK_PARTITION_MISMATCH', 'Carry set contains a non-Flutter URI');
  }
  final packageName = 'patch.$seq.flutter_carry';
  final root = Directory(p.join(destination, 'flutter_carry'));
  await rejectLinks(root.path);
  await root.create(recursive: true);
  final uriRewrites = <String, String>{};
  final exportedNames = <String, Set<String>>{};
  for (final uri in carry) {
    final parsed = Uri.parse(uri);
    final relative = parsed.path.replaceFirst(RegExp(r'^/?flutter/'), '');
    final source = File(p.join(sdkRoot, 'packages/flutter/lib', relative));
    require(await source.exists(), 'FRAMEWORK_CARRY_SOURCE_MISMATCH',
        'Framework source missing for $uri at ${source.path}');
    final target = File(p.join(root.path, relative));
    await target.parent.create(recursive: true);
    final sourceText = await source.readAsString();
    exportedNames[uri] = _publicTypeDeclarations(sourceText);
    await target.writeAsString(rewriteImports(
      sourceText,
      const {},
      uriRewrites: uriRewrites,
      relativeUriRewrites: _relativeFrameworkRewrites(
          relative: relative,
          packageName: packageName,
          carry: carry,
          source: sourceText),
    ));
    uriRewrites[uri] = 'package:$packageName/$relative';
  }
  // A library may be split over part files.  Copy only the files named by
  // `part` directives; copying the whole directory would silently carry
  // unrelated framework libraries and defeat the partition boundary.
  final files = <String>{
    for (final uri in carry)
      Uri.parse(uri).path.replaceFirst(RegExp(r'^/?flutter/'), '')
  };
  final ownerByRelative = <String, String>{
    for (final uri in carry)
      Uri.parse(uri).path.replaceFirst(RegExp(r'^/?flutter/'), ''): uri
  };
  final pending = List<String>.from(files);
  final partPattern = RegExp(r'''\bpart\s+['"]([^'"]+)['"]''');
  for (var i = 0; i < pending.length; i++) {
    final relative = pending[i];
    final source = File(p.join(sdkRoot, 'packages/flutter/lib', relative));
    require(await source.exists(), 'FRAMEWORK_CARRY_SOURCE_MISMATCH',
        'Framework source missing for part $relative');
    final text = await source.readAsString();
    for (final match in partPattern.allMatches(text)) {
      final part = p.normalize(p.join(p.dirname(relative), match.group(1)!));
      final owner = ownerByRelative[relative];
      if (owner != null) ownerByRelative[part] = owner;
      if (files.add(part)) pending.add(part);
    }
  }
  for (final relative in files) {
    final source = File(p.join(sdkRoot, 'packages/flutter/lib', relative));
    final target = File(p.join(root.path, relative));
    await target.parent.create(recursive: true);
    final text = await source.readAsString();
    await target.writeAsString(
        rewriteImports(text, const {},
            uriRewrites: uriRewrites,
            relativeUriRewrites: _relativeFrameworkRewrites(
                relative: relative,
                packageName: packageName,
                carry: carry,
                source: text)));
    // Part files contribute declarations to the containing library's export
    // surface, so include their public types in the barrel hide list.
    final owner = ownerByRelative[relative] ?? '';
    if (owner.isNotEmpty) {
      exportedNames
          .putIfAbsent(owner, () => <String>{})
          .addAll(_publicTypeDeclarations(text));
    }
  }
  final barrelGroups = <String, List<String>>{};
  for (final uri in carry) {
    final path = Uri.parse(uri).path.replaceFirst(RegExp(r'^/?flutter/'), '');
    final parts = path.split('/');
    if (parts.length < 3 || parts.first != 'src') continue;
    final barrel = '${parts[1]}.dart';
    barrelGroups.putIfAbsent(barrel, () => []).add(uri);
  }
  final barrels = <String>[];
  for (final entry in barrelGroups.entries) {
    final classes = <String>{};
    for (final uri in entry.value) {
      Map<String, dynamic>? row;
      for (final candidate in libraries) {
        if (candidate['uri'] == uri) {
          row = candidate;
          break;
        }
      }
      classes.addAll(exportedNames[uri] ?? const <String>{});
      // Keep metadata declarations as a fallback for generated or unusual
      // source files where a declaration is not written on its own line.
      for (final declaration in (row?['declarations'] as List? ?? const [])) {
        if (declaration is String && declaration.contains(':')) {
          final name = declaration.substring(declaration.indexOf(':') + 1);
          if (!name.startsWith('_')) classes.add(name);
        }
      }
    }
    final barrelUri = 'package:flutter/${entry.key}';
    final barrelPath = p.join(root.path, entry.key);
    final exports = entry.value.map((uri) {
      final relative =
          Uri.parse(uri).path.replaceFirst(RegExp(r'^/?flutter/'), '');
      return "export 'package:$packageName/$relative';";
    }).join('\n');
    final names = classes.toList()..sort();
    final hide = names.isEmpty ? '' : ' hide ${names.join(', ')}';
    await File(barrelPath)
        .writeAsString("export '$barrelUri'$hide;\n$exports\n");
    uriRewrites[barrelUri] = 'package:$packageName/${entry.key}';
    barrels.add(barrelUri);
  }
  // Rewrite after all mappings are known; this keeps forward imports stable.
  for (final uri in carry) {
    final relative =
        Uri.parse(uri).path.replaceFirst(RegExp(r'^/?flutter/'), '');
    final source = File(p.join(sdkRoot, 'packages/flutter/lib', relative));
    final target = File(p.join(root.path, relative));
    await target.writeAsString(rewriteImports(
        await source.readAsString(), const {},
        uriRewrites: uriRewrites,
        relativeUriRewrites: _relativeFrameworkRewrites(
            relative: relative,
            packageName: packageName,
            carry: carry,
            source: await source.readAsString())));
  }
  final config = await readObject(packagesConfig);
  final rows = (config['packages'] as List).map((raw) => raw).toList();
  rows.removeWhere((raw) => (raw as Map)['name'] == packageName);
  rows.add({
    'name': packageName,
    'rootUri': root.absolute.uri.toString(),
    'packageUri': '',
  });
  final outputConfig = p.join(destination, 'package_config.json');
  await writeObject(outputConfig, {'configVersion': 2, 'packages': rows});
  return {
    'package': packageName,
    'carried': carry.toList()..sort(),
    'uri_rewrites': uriRewrites,
    'barrels': barrels..sort(),
    'packages': outputConfig,
  };
}
