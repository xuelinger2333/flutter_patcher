import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import '../core.dart';

/// The defines of a host built before build inputs were recorded.
Map<String, String> releaseDefines(String? flavor) => {
  'dart.vm.profile': 'false',
  'dart.vm.product': 'true',
  if (flavor != null && flavor != 'default') 'FLUTTER_APP_FLAVOR': flavor,
};

List<String> defineArgs(Map<String, String> defines) => [
  for (final e in defines.entries) '-D${e.key}=${e.value}',
];

/// The defines flutter_tools takes from the SDK that builds, and the field
/// of `bin/cache/flutter.version.json` each one holds.
const _versionDefines = {
  'FLUTTER_VERSION': 'frameworkVersion',
  'FLUTTER_CHANNEL': 'channel',
  'FLUTTER_GIT_URL': 'repositoryUrl',
  'FLUTTER_FRAMEWORK_REVISION': 'frameworkRevision',
  'FLUTTER_ENGINE_REVISION': 'engineRevision',
  'FLUTTER_DART_VERSION': 'dartSdkVersion',
};

/// Define names flutter_tools sets itself, and the option that sets each.
/// It rejects them, and every name that starts with one, from users.
const _reservedDefines = {
  'FLUTTER_APP_FLAVOR': 'use --flavor',
  'FLUTTER_BUILD_NAME': 'it is the version in pubspec.yaml',
  'FLUTTER_BUILD_NUMBER': 'use --version-code',
  'FLUTTER_VERSION': 'it names the Flutter SDK',
  'FLUTTER_CHANNEL': 'it names the Flutter SDK',
  'FLUTTER_GIT_URL': 'it names the Flutter SDK',
  'FLUTTER_FRAMEWORK_REVISION': 'it names the Flutter SDK',
  'FLUTTER_ENGINE_REVISION': 'it names the Flutter SDK',
  'FLUTTER_DART_VERSION': 'it names the Flutter SDK',
  'FLUTTER_ENABLED_FEATURE_FLAGS': 'flutter_patcher builds without them',
  'dart.': 'the compiler sets it',
};

/// The `flutter build` options that reach only the native build: build
/// takes them and passes them on ([forwardedArgs]), so they are recorded and
/// every patch's `flutter build` gets them too.
void forwardedOptions(ArgParser parser) => parser
  ..addSeparator('Passed on to flutter build:')
  ..addMultiOption(
    'android-project-arg',
    abbr: 'P',
    splitCommas: false,
    valueHelp: 'KEY=VALUE',
    help: 'A Gradle project property (Android).',
  )
  ..addOption(
    'android-project-cache-dir',
    help: 'The Gradle project cache directory (Android).',
  )
  ..addFlag(
    'android-gradle-daemon',
    defaultsTo: null,
    help: 'Whether Gradle runs as a daemon (Android).',
  )
  ..addFlag(
    'android-skip-build-dependency-validation',
    defaultsTo: null,
    help:
        'Whether to skip the Gradle, AGP and Kotlin version checks (Android).',
  )
  ..addFlag(
    'ignore-deprecation',
    negatable: false,
    help: 'Ignore deprecation warnings of the native build (Android).',
  )
  ..addOption(
    'performance-measurement-file',
    help: 'Where flutter build writes its build timings.',
  )
  ..addFlag(
    'fatal-warnings',
    defaultsTo: null,
    help: 'Whether warnings fail the build.',
  )
  ..addFlag(
    'verbose',
    abbr: 'v',
    negatable: false,
    help: 'Verbose flutter build output.',
  );

/// Those of [forwardedOptions], in the order passed on.
const _forwarded = [
  'android-project-arg',
  'android-project-cache-dir',
  'android-gradle-daemon',
  'android-skip-build-dependency-validation',
  'ignore-deprecation',
  'performance-measurement-file',
  'fatal-warnings',
  'verbose',
];

/// Those of [_forwarded] that `flutter build ipa` has too; the others are
/// Android's.
const _iosForwarded = {
  'performance-measurement-file',
  'fatal-warnings',
  'verbose',
};

/// The [forwardedOptions] [args] has, as `flutter build` options, for a
/// build for [platform].
List<String> forwardedArgs(
  ArgResults args,
  String code, {
  required String platform,
}) {
  final result = <String>[];
  for (final name in _forwarded.where(args.wasParsed)) {
    _reject(
      platform != 'ios' || _iosForwarded.contains(name),
      code,
      '--$name is an Android build option. Options passed on for iOS: '
      '${_iosForwarded.map((n) => '--$n').join(', ')}.',
    );
    result.addAll(switch (args[name]) {
      final List values => [for (final v in values) '--$name=$v'],
      final String value => ['--$name=$value'],
      final bool on => [on ? '--$name' : '--no-$name'],
      _ => const <String>[],
    });
  }
  return result;
}

/// What to use instead of a `flutter build` option build does not take.
const _ownOptions = {
  '-t': 'use --target',
  '--build-number': 'use --version-code',
  '--build-name': 'it is the version in pubspec.yaml',
};

/// Why build does not take the option [name]: what to use instead, or why
/// it is not passed on to `flutter build`.
String unknownBuildOption(String name) =>
    '$name is not a build option: ${_ownOptions[name] ?? 'of the flutter '
            'build options, build takes those that reach only the native build '
            '(build --help lists them); flutter_patcher sets the others itself, '
            'or a patch could not reproduce them'}.';

/// The one way `build` and `patch` report an input outside what they take:
/// [code] is the command's `*_CONFIG_INVALID`. Messages name keys, options
/// and files, never a define's value.
void _reject(bool allowed, String code, String message) =>
    require(allowed, code, message);

/// The defines [files] and [defines] give, merged as flutter_tools merges
/// `--dart-define-from-file` and `--dart-define`: files in order, then
/// defines, later ones winning.
Future<Map<String, String>> readDefines(
  List<String> files,
  List<String> defines,
  String code,
) async {
  final result = <String, String>{};
  for (final path in files) {
    final file = File(path);
    _reject(
      await file.exists(),
      code,
      '--dart-define-from-file: no file at $path.',
    );
    final text = await file.readAsString();
    final Map<String, Object?> entries;
    if (text.trim().startsWith('{')) {
      try {
        entries = jsonDecode(text) as Map<String, dynamic>;
      } on FormatException {
        throw Failure(code, '$path is not valid JSON.');
      }
    } else {
      entries = _envFile(text, path, code);
    }
    for (final entry in entries.entries) {
      final value = entry.value;
      _reject(
        value is String || value is num || value is bool,
        code,
        '${entry.key} in $path must be a string, a number or a boolean.',
      );
      result[entry.key] = '$value';
    }
  }
  for (final define in defines) {
    final at = define.indexOf('=');
    _reject(
      at > 0,
      code,
      '--dart-define takes KEY=VALUE, not '
      '${at < 0 ? define : define.substring(0, at + 1)}.',
    );
    result[define.substring(0, at)] = define.substring(at + 1);
  }
  for (final key in result.keys) {
    for (final reserved in _reservedDefines.entries) {
      _reject(
        !key.startsWith(reserved.key),
        code,
        'The define $key is reserved: ${reserved.value}.',
      );
    }
  }
  return result;
}

// flutter_tools' DotEnvRegex and _parseProperty (3.47).
final _envBlock = RegExp(r'^\s*([a-zA-Z_]+[a-zA-Z0-9_]*)\s*=\s*"""\s*(.*)$');
final _envLine = RegExp(r'^\s*([a-zA-Z_]+[a-zA-Z0-9_]*)\s*=\s*(.*)?$');
final _envValues = [
  RegExp(r'^"(.*)"\s*(\#\s*.*)?$'),
  RegExp(r"^'(.*)'\s*(\#\s*.*)?$"),
  RegExp(r'^`(.*)`\s*(\#\s*.*)?$'),
  RegExp(r'^([^#\n\s]*)\s*(?:\s*#\s*(.*))?$'),
];

Map<String, String> _envFile(String text, String path, String code) {
  final result = <String, String>{};
  for (final raw in text.split('\n')) {
    final line = raw.trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    final match = _envLine.firstMatch(line);
    _reject(
      match != null && !_envBlock.hasMatch(line),
      code,
      '$path: not a single-line KEY=VALUE: '
      '${line.split('=').first.trim()}',
    );
    final value = match!.group(2) ?? '';
    result[match.group(1)!] =
        _envValues
            .map((form) => form.firstMatch(value))
            .nonNulls
            .firstOrNull
            ?.group(1) ??
        value;
  }
  return result;
}

/// The build name flutter_tools reads from [project]'s pubspec: its version
/// before `+`, or null when it has none or one that is not a version.
Future<String?> buildName(String project) async {
  final pubspec = loadYaml(
    await File(p.join(project, 'pubspec.yaml')).readAsString(),
  );
  final version = pubspec is Map ? pubspec['version']?.toString() : null;
  if (version == null) return null;
  const part = r'[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*';
  return RegExp('^\\d+\\.\\d+\\.\\d+(-$part)?(\\+$part)?\$').hasMatch(version)
      ? version.split('+').first
      : null;
}

/// The defines flutter_tools takes from the Flutter SDK at [sdk].
Future<Map<String, String>> sdkDefines(String sdk) async {
  final file = File(p.join(sdk, 'bin/cache/flutter.version.json'));
  require(
    await file.exists(),
    'SDK_NOT_READY',
    'SDK cache missing: bin/cache/flutter.version.json',
  );
  final version = jsonDecode(await file.readAsString()) as Map;
  return {
    for (final e in _versionDefines.entries)
      e.key: e.key.endsWith('_REVISION')
          ? (version[e.value] as String).substring(0, 10)
          : version[e.value] as String,
  };
}

/// Everything besides sources that decides what a host's Dart code
/// compiles to. A host's build computes it once and records it; the host's
/// own kernels, its `flutter build` and every patch of it use that record.
class BuildInputs {
  BuildInputs({
    required this.target,
    required this.defines,
    required this.builtins,
    this.flutterArgs = const [],
    this.treeShakeIcons = true,
    this.recorded = true,
  });

  /// What a build of [target] uses: [defines] are the user's, [sdk] those
  /// of the SDK that builds ([sdkDefines]).
  BuildInputs.of({
    required this.target,
    required this.defines,
    required this.flutterArgs,
    this.treeShakeIcons = true,
    required Map<String, String> sdk,
    required String? flavor,
    required String? buildName,
    required String buildNumber,
  }) : recorded = true,
       builtins = {
         if (flavor != null && flavor != 'default')
           'FLUTTER_APP_FLAVOR': flavor,
         'FLUTTER_BUILD_NAME': ?buildName,
         'FLUTTER_BUILD_NUMBER': buildNumber,
         ...sdk,
       };

  /// The inputs [receipt]'s host was built with. A host built before they
  /// were recorded had the entry [target] names, no defines of its user and
  /// only the flavor of flutter_tools' defines in its kernels.
  factory BuildInputs.read(
    Map<String, dynamic> receipt, {
    required String flavor,
    required String target,
  }) {
    final recorded = receipt['build_inputs'];
    if (recorded is! Map) {
      return BuildInputs(
        target: target,
        defines: const {},
        builtins: {if (flavor != 'default') 'FLUTTER_APP_FLAVOR': flavor},
        recorded: false,
      );
    }
    // Schema 2 is a host with its icon fonts whole; flutter_patcher 1.1.1
    // and older read schema 1 only, so they refuse it instead of subsetting
    // its fonts.
    final schema = recorded['schema'];
    require(
      schema == 1 || (schema == 2 && recorded['tree_shake_icons'] == false),
      'PATCH_BASELINE_INCOMPATIBLE',
      'This host was built by a newer flutter_patcher; update flutter_patcher.',
    );
    return BuildInputs(
      target: recorded['target'] as String,
      defines: Map<String, String>.from(recorded['dart_defines'] as Map),
      builtins: Map<String, String>.from(recorded['builtin_defines'] as Map),
      flutterArgs: List<String>.from(recorded['flutter_args'] as List),
      treeShakeIcons: schema == 1,
    );
  }

  /// The entry file, such as `lib/main.dart`.
  final String target;

  /// The user's defines, and those flutter_tools adds by itself.
  final Map<String, String> defines, builtins;

  /// `flutter build` options passed on to it.
  final List<String> flutterArgs;

  /// False when the host carries its icon fonts whole
  /// (`--no-tree-shake-icons`): its code may build IconData at run time, and
  /// a patch neither subsets nor checks icons.
  final bool treeShakeIcons;

  /// False for a host built before build inputs were recorded.
  final bool recorded;

  Map<String, Object?> toJson() => {
    'schema': treeShakeIcons ? 1 : 2,
    'target': target,
    'dart_defines': defines,
    'builtin_defines': builtins,
    'flutter_args': flutterArgs,
    if (!treeShakeIcons) 'tree_shake_icons': false,
  };

  /// The defines of every kernel flutter_patcher compiles itself.
  Map<String, String> get compileDefines => {
    'dart.vm.profile': 'false',
    'dart.vm.product': 'true',
    ...builtins,
    ...defines,
  };

  /// The options that give a `flutter build` run in [project] these inputs,
  /// besides its target and flavor. `build bundle` has no build name.
  Future<List<String>> flutterOptions(
    String project, {
    bool bundle = false,
  }) async {
    final file = p.join(project, '.dart_tool', 'flutter_patcher_defines.json');
    // A file, not --dart-define: values with spaces or `&` do not survive
    // the launcher's batch file on Windows.
    if (defines.isNotEmpty) await writeObject(file, defines);
    return [
      if (builtins['FLUTTER_BUILD_NUMBER'] case final number?) ...[
        '--build-number',
        number,
      ],
      if (builtins['FLUTTER_BUILD_NAME'] case final name? when !bundle) ...[
        '--build-name',
        name,
      ],
      if (defines.isNotEmpty) '--dart-define-from-file=$file',
      // build bundle never subsets fonts, and rejects the option.
      if (!bundle && !treeShakeIcons) '--no-tree-shake-icons',
      if (!bundle) ...flutterArgs,
    ];
  }

  /// The environment of that run. It turns off the feature flags
  /// flutter_tools would otherwise read from the computer and define as
  /// FLUTTER_ENABLED_FEATURE_FLAGS; both are of no use to a phone app.
  Map<String, String> get flutterEnvironment => recorded
      ? const {
          'FLUTTER_WINDOWING': 'false',
          'FLUTTER_ACCESSIBILITY_EVALUATIONS': 'false',
        }
      : const {};

  /// The inputs of a patch of this host built in [project] with [sdk]'s
  /// defines: [overrides] are the defines the patch changes or adds, and
  /// every other input is the host's. [target] is the entry the patch was
  /// asked for, if any.
  Future<PatchInputs> patched({
    required String project,
    required Map<String, String> sdk,
    required Map<String, String> overrides,
    String? target,
  }) async {
    const code = 'PATCH_BUILD_INPUTS_MISMATCH';
    if (recorded) {
      require(
        target == null || target == this.target,
        code,
        'The host was built from ${this.target}, not $target; drop --target.',
      );
      final differing = [
        for (final e in sdk.entries)
          if (builtins[e.key] != e.value) e.key,
      ];
      require(
        differing.isEmpty,
        code,
        'The Flutter SDK differs from the one that built the host in '
        '${differing.join(', ')}; patch with the same SDK.',
      );
      require(
        builtins.containsKey('FLUTTER_BUILD_NAME') ||
            await buildName(project) == null,
        code,
        'The host was built without a version in pubspec.yaml; a patch of '
        'it cannot have one. Remove it, or release a new host.',
      );
    }
    return PatchInputs(
      BuildInputs(
        target: recorded ? this.target : target ?? this.target,
        defines: {...defines, ...overrides},
        builtins: builtins,
        flutterArgs: flutterArgs,
        treeShakeIcons: treeShakeIcons,
        recorded: recorded,
      ),
      changed: [
        for (final e in overrides.entries)
          if (defines.containsKey(e.key) && defines[e.key] != e.value) e.key,
      ]..sort(),
      added: [
        for (final key in overrides.keys)
          if (!defines.containsKey(key)) key,
      ]..sort(),
    );
  }
}

/// A patch's inputs, and the defines in which they differ from its host's.
class PatchInputs {
  PatchInputs(this.inputs, {required this.changed, required this.added});
  final BuildInputs inputs;
  final List<String> changed, added;

  /// Null when the patch has its host's defines.
  Map<String, Object?>? get report => changed.isEmpty && added.isEmpty
      ? null
      : {'changed': changed, 'added': added};
}
