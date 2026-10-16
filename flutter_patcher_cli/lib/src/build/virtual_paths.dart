import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;

/// Multi-root scheme for host-independent kernel source URIs.
const virtualScheme = 'org-dartlang-root';

/// A package_config whose package roots under [roots] are rewritten to
/// [virtualScheme], so the baseline kernel records `org-dartlang-root:///...`
/// instead of absolute cache and per-run work paths. Without it app.dill, and
/// with it the fingerprint, differs between hosts and between runs. A package
/// outside every root, or one an earlier root would shadow, keeps its file
/// URI: still correct, only not reproducible.
class VirtualPackages {
  /// Multi-root directories, in gen_kernel's lookup order.
  final List<String> roots;

  /// The rewritten config's own URI, for `--packages`.
  final String packagesUri;

  VirtualPackages._(this.roots, this.packagesUri);

  List<String> get compilerArgs => [
        '--filesystem-scheme',
        virtualScheme,
        for (final root in roots) ...['--filesystem-root', root]
      ];

  /// Writes the rewritten copy of [packages] into `roots.first`.
  static Future<VirtualPackages> write(
      String packages, List<String> roots) async {
    final source = File(packages).absolute;
    final config = jsonDecode(await source.readAsString()) as Map;
    final rows = <Map>[];
    for (final row in (config['packages'] as List).cast<Map>()) {
      final location = source.uri.resolve(row['rootUri'] as String);
      rows.add({...row, 'rootUri': _virtual(location, roots) ?? '$location'});
    }
    const name = 'package_config.virtual.json';
    await File(p.join(roots.first, name))
        .writeAsString(jsonEncode({...config, 'packages': rows}));
    return VirtualPackages._(roots, '$virtualScheme:///$name');
  }

  /// The virtual URI for [location], from the first root containing it.
  /// A later root is used only when no earlier root shadows the first path
  /// segment, since gen_kernel resolves each file against the roots in order.
  static String? _virtual(Uri location, List<String> roots) {
    final path = location.toFilePath();
    for (var i = 0; i < roots.length; i++) {
      if (!p.equals(roots[i], path) && !p.isWithin(roots[i], path)) continue;
      final segments = p.split(p.relative(path, from: roots[i]));
      if (segments.first == '.') segments.clear();
      if (segments.isNotEmpty &&
          roots.take(i).any((earlier) =>
              FileSystemEntity.typeSync(p.join(earlier, segments.first)) !=
              FileSystemEntityType.notFound)) {
        return null;
      }
      return '$virtualScheme:///${segments.map(Uri.encodeComponent).join('/')}/';
    }
    return null;
  }
}
