import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

/// A place in a source file, `path:line` relative to its package.
typedef SourceSite = ({String package, String file, int line});

String siteText(SourceSite s) => '${s.package}/${s.file}:${s.line}';

/// Read-only scans of a build copy's sources. They only gather facts; the
/// rules decide what the facts mean for a patch.
class SourceScan {
  SourceScan(this.roots, this.app, {required this.sdkRoots});

  /// Package name to its `lib/` URI (see `packageRoots`).
  final Map<String, dynamic> roots;
  final String app;

  /// Flutter SDKs whose packages the build copy may resolve to.
  final List<String> sdkRoots;

  static const _reserved = {'dynamic_modules', 'flutter_patcher'};

  Directory _dir(String name) =>
      Directory.fromUri((roots[name] as Uri).resolve('..'));

  /// The application and its local path packages: code the developer owns,
  /// not a pub cache or SDK package.
  late final List<String> own = [
    app,
    for (final name in roots.keys)
      if (name != app && !_reserved.contains(name) && _local(name)) name,
  ];

  bool _local(String name) {
    final dir = p.normalize(_dir(name).absolute.path);
    if (sdkRoots.any((sdk) => p.isWithin(p.normalize(sdk), dir))) return false;
    final parts = p.split(dir).map((s) => s.toLowerCase()).toList();
    return !parts.contains('hosted') &&
        !parts.contains('git') &&
        !parts.contains('pub-cache') &&
        !parts.contains('.pub-cache');
  }

  static final _nativeFile = {
    'android': RegExp(r'\.(kt|java)$'),
    'ios': RegExp(r'\.(swift|m|mm|h)$'),
  };
  static final _platformDirs = {
    'android': ['android'],
    'ios': ['ios', 'darwin'],
  };
  static final _testDir = RegExp(
    r'(^|/)(test|androidTest|RunnerTests|Tests?)/',
  );
  static final _assetLookup = RegExp(
    r'getLookupKeyForAsset|lookupKeyForAsset|flutter_assets/',
  );

  /// Packages whose native code on [platform] opens Flutter assets itself,
  /// through the platform's asset manager rather than the engine. Plugins
  /// and the application are read; each package reports its first site.
  Future<Map<String, SourceSite>> nativeAssetReaders(String platform) async {
    final found = <String, SourceSite>{};
    for (final name in roots.keys) {
      if (_reserved.contains(name) || !(name == app || await _plugin(name))) {
        continue;
      }
      final base = _dir(name);
      for (final top in _platformDirs[platform]!) {
        final dir = Directory(p.join(base.path, top));
        if (!await dir.exists()) continue;
        await for (final entity in dir.list(
          recursive: true,
          followLinks: false,
        )) {
          if (entity is! File ||
              !_nativeFile[platform]!.hasMatch(entity.path)) {
            continue;
          }
          final relative = p
              .relative(entity.path, from: base.path)
              .replaceAll('\\', '/');
          if (_testDir.hasMatch(relative)) continue;
          final line = _firstLine(await _read(entity), _assetLookup);
          if (line != null) {
            found[name] = (package: name, file: relative, line: line);
            break;
          }
        }
        if (found.containsKey(name)) break;
      }
    }
    return found;
  }

  Future<bool> _plugin(String name) async {
    final spec = File(p.join(_dir(name).path, 'pubspec.yaml'));
    if (!await spec.exists()) return false;
    final data = loadYaml(await spec.readAsString());
    return data is Map &&
        data['flutter'] is Map &&
        (data['flutter'] as Map)['plugin'] != null;
  }

  /// Where own Dart code that imports one of [readers] names one of [assets]
  /// in a string literal: the asset most likely reaches that native reader.
  Future<Map<String, List<SourceSite>>> assetsPassedTo(
    Iterable<String> readers,
    Iterable<String> assets,
  ) async {
    final result = <String, List<SourceSite>>{};
    if (readers.isEmpty || assets.isEmpty) return result;
    final imports = RegExp(
      "import\\s+['\"]package:(${readers.map(RegExp.escape).join('|')})/",
    );
    await _eachOwnDart((site, text) {
      if (!imports.hasMatch(text)) return;
      for (final key in assets) {
        final line = _firstLine(
          text,
          RegExp("['\"]${RegExp.escape(key)}['\"]"),
        );
        if (line != null) {
          result.putIfAbsent(key, () => []).add((
            package: site.package,
            file: site.file,
            line: line,
          ));
        }
      }
    });
    return result;
  }

  static final _entryPoint = RegExp(
    r'''@pragma\(\s*['"]vm:entry-point['"][^)]*\)\s*'''
    r'''(?:@\w+(?:\([^)]*\))?\s*)*'''
    r'''(?:(?:static|external)\s+)*'''
    r'''(?:[\w<>?,\s]+?\s+)?(\w+)\s*\(''',
  );
  static final _registration = RegExp(
    r'PluginUtilities\.getCallbackHandle|onBackgroundMessage|'
    r'Workmanager\(\)\s*\.\s*(?:initialize|registerOneOffTask|registerPeriodicTask)|'
    r'AndroidAlarmManager\.|BackgroundFetch\.|FlutterBackgroundService|'
    r'onDidReceiveBackgroundNotificationResponse|registerHeadlessTask',
  );

  /// Functions of own code that native code may start in a separate engine
  /// (entry points other than main), and the calls that register them.
  Future<({List<(String, SourceSite)> entries, List<SourceSite> registrations})>
  backgroundEntries() async {
    final entries = <(String, SourceSite)>[];
    final registrations = <SourceSite>[];
    await _eachOwnDart((site, text) {
      for (final m in _entryPoint.allMatches(text)) {
        final name = m.group(1)!;
        if (name == 'main') continue;
        entries.add((
          name,
          (
            package: site.package,
            file: site.file,
            // The function's own line, not its annotation's.
            line: _lineAt(text, m.start + m.group(0)!.lastIndexOf(name)),
          ),
        ));
      }
      for (final m in _registration.allMatches(text)) {
        registrations.add((
          package: site.package,
          file: site.file,
          line: _lineAt(text, m.start),
        ));
      }
    });
    return (entries: entries, registrations: registrations);
  }

  Future<void> _eachOwnDart(void Function(SourceSite, String) visit) async {
    for (final name in own) {
      final lib = Directory.fromUri(roots[name] as Uri);
      if (!await lib.exists()) continue;
      final base = _dir(name).path;
      await for (final entity in lib.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        final relative = p
            .relative(entity.path, from: base)
            .replaceAll('\\', '/');
        visit((package: name, file: relative, line: 0), await _read(entity));
      }
    }
  }

  static Future<String> _read(File file) async {
    try {
      return await file.readAsString();
    } on FileSystemException {
      return ''; // Not UTF-8 text: nothing a pattern here would match.
    }
  }

  static int? _firstLine(String text, RegExp pattern) {
    final m = pattern.firstMatch(text);
    return m == null ? null : _lineAt(text, m.start);
  }

  static int _lineAt(String text, int offset) =>
      '\n'.allMatches(text.substring(0, offset)).length + 1;
}
