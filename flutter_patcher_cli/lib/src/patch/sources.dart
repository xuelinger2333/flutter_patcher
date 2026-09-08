import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import '../core.dart';

/// Rewrite URI literals only in directives, leaving runtime strings untouched.
String rewriteImports(String source, Map<String, String> names) {
  var directive = false, previous = 0;
  final out = StringBuffer();
  var i = 0;
  bool identifier(String c) => RegExp(r'[A-Za-z_0-9$]').hasMatch(c);
  while (i < source.length) {
    if (source.startsWith('//', i)) {
      final end = source.indexOf('\n', i);
      i = end < 0 ? source.length : end;
      continue;
    }
    if (source.startsWith('/*', i)) {
      var depth = 1;
      i += 2;
      while (i < source.length && depth > 0) {
        if (source.startsWith('/*', i)) {
          depth++;
          i += 2;
        } else if (source.startsWith('*/', i)) {
          depth--;
          i += 2;
        } else {
          i++;
        }
      }
      continue;
    }
    final start = i;
    final raw = source[i] == 'r' &&
        i + 1 < source.length &&
        ["'", '"'].contains(source[i + 1]);
    if (raw) i++;
    if (!["'", '"'].contains(source[i])) {
      if (identifier(source[i])) {
        i++;
        while (i < source.length && identifier(source[i])) {
          i++;
        }
        final word = source.substring(start, i);
        if (['import', 'export', 'part', 'library'].contains(word)) {
          directive = true;
        } else if (!directive) {
          // Directives precede declarations. Do not lex interpolation or
          // runtime expressions in the body of the library.
          break;
        }
      } else {
        if (source[i] == ';') directive = false;
        i++;
      }
      continue;
    }
    final delimiter =
        source.startsWith(source[i] * 3, i) ? source[i] * 3 : source[i];
    i += delimiter.length;
    final begin = i;
    while (i < source.length && !source.startsWith(delimiter, i)) {
      if (!raw && source[i] == '\\') {
        i += 2;
      } else {
        i++;
      }
    }
    require(i < source.length, 'PATCH_SOURCE_INVALID',
        'Unterminated source string');
    final end = i;
    i += delimiter.length;
    if (!directive) continue;
    final content = source.substring(begin, end);
    require(
        !content.contains('\\') && !content.contains(r'$'),
        'PATCH_SOURCE_INVALID',
        'Escaped/interpolated directive URIs are unsupported');
    final uri = Uri.tryParse(content);
    if (uri?.scheme != 'package' ||
        uri!.pathSegments.isEmpty ||
        !names.containsKey(uri.pathSegments.first)) {
      continue;
    }
    final replacement = content.replaceFirst(
        'package:${uri.pathSegments.first}/',
        'package:${names[uri.pathSegments.first]}/');
    out.write(source.substring(previous, start));
    out.write('${raw ? 'r' : ''}$delimiter$replacement$delimiter');
    previous = i;
  }
  out.write(source.substring(previous));
  return out.toString();
}

Future<Map<String, dynamic>> packageRoots(String config) async {
  final data = await readObject(config);
  return {
    for (final row in data['packages'] as List)
      row['name'] as String: File(config)
          .absolute
          .uri
          .resolve(
              '${(row['rootUri'] as String).replaceFirst(RegExp(r'/+$'), '')}/')
          .resolve(row['packageUri'] as String? ?? 'lib/')
  };
}

Future<Map<String, Object?>> remapSources(
    String config, String destination, Set<String> own, int seq) async {
  final data = await readObject(config);
  final roots = await packageRoots(config);
  final names = {for (final name in own) name: 'patch.$seq.$name'};
  final rows = <Object>[];
  for (final raw in data['packages'] as List) {
    final row = Map<String, dynamic>.from(raw as Map),
        name = row['name'] as String;
    final source = Directory.fromUri(roots[name] as Uri);
    if (!own.contains(name)) {
      row['rootUri'] = source.uri.toString();
      row['packageUri'] = '';
      rows.add(row);
      continue;
    }
    final target = p.join(destination, name);
    await Directory(target).create(recursive: true);
    await for (final entity
        in source.list(recursive: true, followLinks: false)) {
      final output = p.join(target, p.relative(entity.path, from: source.path));
      if (entity is Link) {
        throw Failure('PATCH_SOURCE_INVALID', 'Symlink in module sources');
      }
      if (entity is! File) continue;
      await File(output).parent.create(recursive: true);
      if (entity.path.endsWith('.dart')) {
        await File(output)
            .writeAsString(rewriteImports(await entity.readAsString(), names));
      } else {
        await entity.copy(output);
      }
    }
    rows.add({
      ...row,
      'name': names[name],
      'rootUri': Directory(target).absolute.uri.toString(),
      'packageUri': ''
    });
  }
  final result = p.join(destination, 'package_config.json');
  await writeObject(result, {'configVersion': 2, 'packages': rows});
  return {'packages': result, 'names': names};
}

String patchEntry(String package, String target, int seq, String fingerprint,
        String tier) =>
    'import ${jsonEncode('package:$package/$target').replaceAll(r'$', r'\$')} as app;\n'
    '@pragma("vm:entry-point")\n@pragma("dyn-module:entry-point")\n'
    'Object? dynamicModuleEntrypoint() => <Object?>[1,$seq,"$fingerprint","$tier",app.main,null];\n';
