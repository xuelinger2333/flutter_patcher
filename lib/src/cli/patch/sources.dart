import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../core.dart';

/// Rewrite URI literals only in directives, leaving runtime strings untouched.
String rewriteImports(
  String source,
  Map<String, String> names, {
  Map<String, String> relativeUriRewrites = const {},
  String? Function(String uri, String directive)? rewriteUri,
}) {
  var directive = false, previous = 0;
  var directiveKind = '';
  var directiveDepth = 0;
  final out = StringBuffer();
  var i = source.startsWith('#!') ? source.indexOf('\n') : 0;
  if (i < 0) return source;
  bool identifier(String c) => RegExp(r'[A-Za-z_0-9$]').hasMatch(c);
  void whitespace() {
    while (i < source.length) {
      if (' \t\r\n'.contains(source[i])) {
        i++;
      } else if (source.startsWith('//', i)) {
        final end = source.indexOf('\n', i);
        i = end < 0 ? source.length : end;
      } else if (source.startsWith('/*', i)) {
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
        require(
          depth == 0,
          'PATCH_SOURCE_INVALID',
          'Unterminated directive comment',
        );
      } else {
        break;
      }
    }
  }

  void balanced(String open, String close) {
    var depth = 0;
    do {
      final raw =
          source[i] == 'r' &&
          i + 1 < source.length &&
          ["'", '"'].contains(source[i + 1]);
      if (raw) i++;
      if (["'", '"'].contains(source[i])) {
        final quote = source.startsWith(source[i] * 3, i)
            ? source[i] * 3
            : source[i];
        i += quote.length;
        while (i < source.length && !source.startsWith(quote, i)) {
          if (!raw && source[i] == '\\') {
            i += 2;
          } else if (!raw && source.startsWith(r'${', i)) {
            i++;
            balanced('{', '}');
          } else {
            i++;
          }
        }
        require(
          i < source.length,
          'PATCH_SOURCE_INVALID',
          'Unterminated annotation string',
        );
        i += quote.length;
        continue;
      }
      if (source.startsWith('//', i)) {
        final end = source.indexOf('\n', i);
        i = end < 0 ? source.length : end;
        continue;
      }
      if (source.startsWith('/*', i)) {
        var comments = 1;
        i += 2;
        while (i < source.length && comments > 0) {
          if (source.startsWith('/*', i)) {
            comments++;
            i += 2;
          } else if (source.startsWith('*/', i)) {
            comments--;
            i += 2;
          } else {
            i++;
          }
        }
        continue;
      }
      if (source[i] == open) depth++;
      if (source[i] == close) depth--;
      i++;
    } while (i < source.length && depth > 0);
    require(
      depth == 0,
      'PATCH_SOURCE_INVALID',
      'Unterminated directive annotation',
    );
  }

  void annotation() {
    i++; // @
    whitespace();
    while (i < source.length) {
      while (i < source.length && identifier(source[i])) {
        i++;
      }
      whitespace();
      if (i >= source.length || source[i] != '.') break;
      i++;
      whitespace();
    }
    // Metadata may have type arguments and nested constant expressions.
    for (final delimiters in [('<', '>'), ('(', ')')]) {
      if (i >= source.length || source[i] != delimiters.$1) continue;
      balanced(delimiters.$1, delimiters.$2);
      whitespace();
      if (delimiters.$1 == '<' && i < source.length && source[i] == '.') {
        i++;
        whitespace();
        while (i < source.length && identifier(source[i])) {
          i++;
        }
        whitespace();
      }
    }
  }

  while (i < source.length) {
    if (source[i] == '@' && !directive) {
      annotation();
      continue;
    }
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
    final raw =
        source[i] == 'r' &&
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
          directiveKind = word;
        } else if (directive && directiveKind == 'part' && word == 'of') {
          directiveKind = 'part of';
        } else if (!directive) {
          // Directives precede declarations. Do not lex interpolation or
          // runtime expressions in the body of the library.
          break;
        }
      } else {
        if (source[i] == ';') directive = false;
        if (directive && source[i] == '(') directiveDepth++;
        if (directive && source[i] == ')') directiveDepth--;
        i++;
      }
      continue;
    }
    // A URI may be written as adjacent literals ('package:a' '/b.dart'),
    // which the language concatenates; rewrite the run as one literal.
    final parts = <String>[];
    String readLiteral(bool isRaw) {
      final delimiter = source.startsWith(source[i] * 3, i)
          ? source[i] * 3
          : source[i];
      i += delimiter.length;
      final begin = i;
      while (i < source.length && !source.startsWith(delimiter, i)) {
        if (!isRaw && source[i] == '\\') {
          i += 2;
        } else {
          i++;
        }
      }
      require(
        i < source.length,
        'PATCH_SOURCE_INVALID',
        'Unterminated source string',
      );
      final end = i;
      i += delimiter.length;
      return source.substring(begin, end);
    }

    parts.add(readLiteral(raw));
    while (directive) {
      var j = i;
      while (j < source.length && ' \t\r\n'.contains(source[j])) {
        j++;
      }
      final nextRaw =
          j + 1 < source.length &&
          source[j] == 'r' &&
          ["'", '"'].contains(source[j + 1]);
      if (!nextRaw && (j >= source.length || !["'", '"'].contains(source[j]))) {
        break;
      }
      i = nextRaw ? j + 1 : j;
      parts.add(readLiteral(nextRaw));
    }
    if (!directive || directiveDepth != 0) continue;
    final content = parts.join();
    require(
      !content.contains('\\') && !content.contains(r'$'),
      'PATCH_SOURCE_INVALID',
      'Escaped/interpolated directive URIs are unsupported',
    );
    final uri = Uri.tryParse(content);
    String? replacement =
        rewriteUri?.call(content, directiveKind) ??
        relativeUriRewrites[content];
    if (replacement == null &&
        uri?.scheme == 'package' &&
        uri!.pathSegments.isNotEmpty &&
        names.containsKey(uri.pathSegments.first)) {
      replacement = content.replaceFirst(
        'package:${uri.pathSegments.first}/',
        'package:${names[uri.pathSegments.first]}/',
      );
    }
    if (replacement == null) continue;
    out.write(source.substring(previous, start));
    out.write("'$replacement'");
    previous = i;
  }
  out.write(source.substring(previous));
  return out.toString();
}

Future<Map<String, dynamic>> packageRoots(String config) async {
  final data = await readObject(config);
  return {
    for (final row in data['packages'] as List)
      row['name'] as String: File(config).absolute.uri
          .resolve(
            '${(row['rootUri'] as String).replaceFirst(RegExp(r'/+$'), '')}/',
          )
          .resolve(row['packageUri'] as String? ?? 'lib/'),
  };
}

Future<Map<String, Object?>> remapSources(
  String config,
  String destination,
  Set<String> own,
  int seq,
  Set<String> selected,
) async {
  final data = await readObject(config);
  final roots = await packageRoots(config);
  final names = {for (final name in own) name: 'patch.$seq.$name'};
  final rows = <Object>[];
  for (final raw in data['packages'] as List) {
    final row = Map<String, dynamic>.from(raw as Map),
        name = row['name'] as String;
    final source = Directory.fromUri(roots[name] as Uri);
    // Keep the original URI available: unchanged libraries link to the host.
    rows.add({...row, 'rootUri': source.uri.toString(), 'packageUri': ''});
    if (!own.contains(name)) continue;
    final target = p.join(destination, name);
    await Directory(target).create(recursive: true);
    await for (final entity in source.list(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is Link) {
        throw Failure('PATCH_SOURCE_INVALID', 'Symlink in module sources');
      }
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final relative = p
          .relative(entity.path, from: source.path)
          .replaceAll('\\', '/');
      final identity = Uri.parse('package:$name/$relative');
      if (!selected.contains(identity.toString())) continue;
      final output = p.join(target, relative);
      await File(output).parent.create(recursive: true);
      await File(output).writeAsString(
        rewriteImports(
          await entity.readAsString(),
          const {},
          rewriteUri: (value, _) {
            final uri = identity.resolve(value);
            if (uri.scheme != 'package') return null;
            if (!selected.contains(uri.toString())) return uri.toString();
            final package = uri.pathSegments.first;
            return uri.toString().replaceFirst(
              'package:$package/',
              'package:${names[package]}/',
            );
          },
        ),
      );
    }
    rows.add({
      ...row,
      'name': names[name],
      'rootUri': Directory(target).absolute.uri.toString(),
      'packageUri': '',
    });
  }
  final result = p.join(destination, 'package_config.json');
  await writeObject(result, {'configVersion': 2, 'packages': rows});
  return {'packages': result, 'names': names};
}

/// Select changed libraries and the libraries that must refer to their new
/// identities. Unchanged dependencies stay in the host; parts share their
/// owner's identity and are always copied together. A newly reached library
/// absent from the host must also be supplied by the module.
Future<Set<String>> selectPatchSources({
  required String config,
  required Set<String> packages,
  required Iterable<String> changed,
  required Set<String> baselineSources,
  required String entry,
}) async {
  final roots = await packageRoots(config);
  final compiled = baselineSources
      .map((uri) => Uri.parse(uri).toString())
      .toSet();
  final dependencies = <String, Set<String>>{};
  final parts = <String, Set<String>>{};
  for (final name in packages.toList()..sort()) {
    final root = roots[name] as Uri?;
    if (root == null) continue;
    final directory = Directory.fromUri(root);
    if (!await directory.exists()) continue;
    await for (final file in directory.list(
      recursive: true,
      followLinks: false,
    )) {
      require(
        file is! Link,
        'PATCH_SOURCE_INVALID',
        'Symlink in module sources',
      );
      if (file is! File || !file.path.endsWith('.dart')) continue;
      final relative = p
          .relative(file.path, from: directory.path)
          .replaceAll('\\', '/');
      final uri = Uri.parse('package:$name/$relative');
      final key = uri.toString();
      dependencies[key] = {};
      rewriteImports(
        await file.readAsString(),
        const {},
        rewriteUri: (value, kind) {
          final target = uri.resolve(value).toString();
          if (kind == 'part') parts.putIfAbsent(key, () => {}).add(target);
          if (kind != 'part of') dependencies[key]!.add(target);
          return null;
        },
      );
    }
  }
  final selected = <String>{
    Uri.parse(entry).toString(),
    for (final uri in changed)
      if (uri.startsWith('package:') &&
          (packages.contains(Uri.parse(uri).pathSegments.first) ||
              !roots.containsKey(Uri.parse(uri).pathSegments.first)))
        Uri.parse(uri).toString(),
  };
  var added = true;
  while (added) {
    added = false;
    for (final row in dependencies.entries) {
      // Recompile callers, including export barrels, so they cannot keep
      // calling the old host library. This also closes cycles.
      if (compiled.contains(row.key) &&
          row.value.any(selected.contains) &&
          selected.add(row.key)) {
        added = true;
      }
      if (!selected.contains(row.key)) continue;
      for (final target in row.value) {
        if (dependencies.containsKey(target) &&
            (!compiled.contains(target) ||
                (parts[row.key]?.contains(target) ?? false)) &&
            selected.add(target)) {
          added = true;
        }
      }
    }
  }
  for (final source in selected) {
    for (final target in dependencies[source] ?? const <String>{}) {
      require(
        !selected.contains(target) || dependencies.containsKey(target),
        'PATCH_SOURCE_INVALID',
        '$source still references deleted source $target; remove or update the directive',
      );
    }
  }
  return (selected.intersection(dependencies.keys.toSet()).toList()..sort())
      .toSet();
}

String patchEntry(
  String package,
  String target,
  int seq,
  String fingerprint,
  String tier,
) =>
    'import ${jsonEncode('package:$package/$target').replaceAll(r'$', r'\$')} as app;\n'
    '@pragma("vm:entry-point")\n@pragma("dyn-module:entry-point")\n'
    'Object? dynamicModuleEntrypoint() => <Object?>[1,$seq,"$fingerprint","$tier",app.main,null];\n';

/// The libraries of [config]'s packages that read each of the defines
/// [keys]: those that name the key in a string literal and call
/// `fromEnvironment` or `hasEnvironment`, which is how a define reaches
/// code, also when a constant holds its name.
Future<Map<String, List<String>>> defineReaders(
  String config,
  List<String> keys,
) async {
  final readers = {for (final key in keys) key: <String>[]};
  if (keys.isEmpty) return readers;
  final reads = RegExp('(from|has)Environment');
  final roots = await packageRoots(config);
  for (final name in roots.keys.toList()..sort()) {
    final root = Directory.fromUri(roots[name] as Uri);
    if (!await root.exists()) continue;
    final files = await root
        .list(recursive: true, followLinks: false)
        .where((e) => e is File && e.path.endsWith('.dart'))
        .toList();
    for (final file in files..sort((a, b) => a.path.compareTo(b.path))) {
      final String text;
      try {
        text = await (file as File).readAsString();
      } on FileSystemException {
        continue; // Not UTF-8 text: no Dart library.
      }
      if (!reads.hasMatch(text)) continue;
      final relative = p
          .relative(file.path, from: root.path)
          .replaceAll('\\', '/');
      for (final key in keys) {
        if (text.contains("'$key'") || text.contains('"$key"')) {
          readers[key]!.add('package:$name/$relative');
        }
      }
    }
  }
  return readers;
}
