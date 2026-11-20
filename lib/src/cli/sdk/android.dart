import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;

import '../core.dart';
import 'host.dart';

/// Android SDK root: `ANDROID_HOME`, then `ANDROID_SDK_ROOT`, then the
/// location Android Studio uses on each host. Returns null when none holds a
/// `build-tools` directory.
String? locateAndroidSdk(
  HostIdentity host, {
  Map<String, String>? environment,
}) {
  final env = environment ?? Platform.environment;
  final home = env['HOME'] ?? env['USERPROFILE'];
  final candidates = <String?>[
    env['ANDROID_HOME'],
    env['ANDROID_SDK_ROOT'],
    if (host.isWindows && env['LOCALAPPDATA'] != null)
      p.join(env['LOCALAPPDATA']!, 'Android', 'Sdk'),
    if (host.os == 'macos' && home != null)
      p.join(home, 'Library', 'Android', 'sdk'),
    if (host.os == 'linux' && home != null) p.join(home, 'Android', 'Sdk'),
  ];
  for (final candidate in candidates) {
    if (candidate != null &&
        candidate.isNotEmpty &&
        Directory(p.join(candidate, 'build-tools')).existsSync()) {
      return candidate;
    }
  }
  return null;
}

/// The Android SDK the way Flutter itself resolves it: `flutter config
/// --android-sdk` first, then [locateAndroidSdk]. Gradle builds use Flutter's
/// choice, so the CLI must not reject a host where only the config is set.
Future<String> resolveAndroidSdk(
  Commands commands,
  HostIdentity host,
  String flutterLauncher,
) async {
  String? configured;
  final result = await commands.runResult(flutterLauncher, [
    '--suppress-analytics',
    'config',
    '--machine',
  ]);
  final start = result.stdout.indexOf('{');
  if (result.exitCode == 0 && start >= 0) {
    try {
      configured =
          (jsonDecode(result.stdout.substring(start)) as Map)['android-sdk']
              as String?;
    } on FormatException {
      configured = null;
    }
  }
  final sdk =
      configured != null &&
          Directory(p.join(configured, 'build-tools')).existsSync()
      ? configured
      : locateAndroidSdk(host);
  require(
    sdk != null,
    'ANDROID_SDK_MISSING',
    'No Android SDK: select one with flutter config --android-sdk or ANDROID_HOME.',
  );
  return sdk!;
}

/// Numeric build-tools ordering: `34.0.0` sorts after `9.0.0`, and
/// pre-release suffixes (`35.0.0-rc1`) sort before the matching release.
int compareBuildToolsVersions(String a, String b) {
  List<Object> parts(String v) {
    final match = RegExp(r'^(\d+)\.(\d+)\.(\d+)(?:-(.+))?$').firstMatch(v);
    if (match == null) return [-1, -1, -1, v];
    return [
      int.parse(match[1]!),
      int.parse(match[2]!),
      int.parse(match[3]!),
      match[4] ?? '~', // '~' sorts after any rc tag
    ];
  }

  final x = parts(a), y = parts(b);
  for (var i = 0; i < 4; i++) {
    final c = x[i] is int
        ? (x[i] as int).compareTo(y[i] as int)
        : (x[i] as String).compareTo(y[i] as String);
    if (c != 0) return c;
  }
  return 0;
}

/// Newest build-tools directory that ships `aapt` for this host.
Future<String> selectAapt(String androidSdk, HostIdentity host) async {
  final buildTools = await Directory(p.join(androidSdk, 'build-tools'))
      .list()
      .where((f) => f is Directory)
      .map((d) => d.path)
      .toList();
  buildTools.sort(
    (a, b) => compareBuildToolsVersions(p.basename(b), p.basename(a)),
  );
  for (final directory in buildTools) {
    final aapt = p.join(directory, host.exe('aapt'));
    if (File(aapt).existsSync()) return aapt;
  }
  throw Failure('ANDROID_SDK_MISSING', 'Android build-tools aapt is missing.');
}

/// `flutter build apk` finds a JDK through JAVA_HOME, `flutter config
/// --jdk-dir` or Android Studio's bundled runtime, so the JDK is only checked
/// when JAVA_HOME is set and would otherwise mislead Gradle.
void checkJavaHome(HostIdentity host, {Map<String, String>? environment}) {
  final javaHome = (environment ?? Platform.environment)['JAVA_HOME'];
  if (javaHome == null || javaHome.isEmpty) return;
  require(
    File(p.join(javaHome, 'bin', host.exe('java'))).existsSync(),
    'JAVA_HOME_INVALID',
    'JAVA_HOME does not contain bin/java: $javaHome',
  );
}

/// What differs between the packages an Android host is built as. The
/// build, the host it makes and every patch of it are otherwise the same.
class AndroidPackage {
  const AndroidPackage._(this.command, this.extension, this.prefix, this.noun);

  /// `flutter build <command>` builds it.
  final String command;

  /// Its file extension.
  final String extension;

  /// Where it keeps what an APK keeps at its root: an app bundle's base
  /// module.
  final String prefix;

  /// What messages call it.
  final String noun;

  static const apk = AndroidPackage._('apk', 'apk', '', 'APK');
  static const appbundle = AndroidPackage._(
    'appbundle',
    'aab',
    'base/',
    'app bundle',
  );

  /// The package the file at [path] is, by its extension.
  static AndroidPackage of(String path) =>
      path.endsWith('.aab') ? appbundle : apk;

  /// The release package `flutter build` left in [project] for [flavor],
  /// where flutter_tools itself looks for it.
  Future<String> output(String project, String? flavor) async {
    final outputs = p.join(project, 'build', 'app', 'outputs');
    if (this == apk) {
      return p.join(
        outputs,
        'flutter-apk',
        'app${flavor == null ? '' : '-${flavor.toLowerCase()}'}-release.apk',
      );
    }
    final variant = '${flavor?.toLowerCase() ?? ''}release';
    final directory = Directory(p.join(outputs, 'bundle'));
    final found = await directory.exists()
        ? await directory
              .list(recursive: true)
              .where(
                (entry) =>
                    entry is File &&
                    entry.path.endsWith('release.aab') &&
                    p.basename(p.dirname(entry.path)).toLowerCase() == variant,
              )
              .map((entry) => entry.path)
              .toList()
        : <String>[];
    require(
      found.length == 1,
      'BUILD_APK_INVALID',
      'Expected one $variant app bundle under ${directory.path}, found '
          '${found.length}.',
    );
    return found.single;
  }
}

/// The files of the Android package at [path] by their APK paths: an app
/// bundle's base module, its `base/` dropped. Nothing else of a bundle
/// reaches a device.
Future<Archive> readAndroidPackage(String path) async {
  final archive = ZipDecoder().decodeBytes(await File(path).readAsBytes());
  final prefix = AndroidPackage.of(path).prefix;
  if (prefix.isEmpty) return archive;
  final base = Archive();
  for (final file in archive) {
    if (!file.isFile || !file.name.startsWith(prefix)) continue;
    final content = file.content as List<int>;
    base.addFile(
      ArchiveFile(file.name.substring(prefix.length), content.length, content),
    );
  }
  return base;
}
