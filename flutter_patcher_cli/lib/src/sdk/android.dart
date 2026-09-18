import 'dart:io';
import 'package:path/path.dart' as p;
import '../core.dart';
import 'host.dart';

/// Android SDK root: `ANDROID_HOME`, then `ANDROID_SDK_ROOT`, then the
/// location Android Studio uses on each host. Returns null when none holds a
/// `build-tools` directory.
String? locateAndroidSdk(HostIdentity host,
    {Map<String, String>? environment}) {
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
  buildTools
      .sort((a, b) => compareBuildToolsVersions(p.basename(b), p.basename(a)));
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
  require(File(p.join(javaHome, 'bin', host.exe('java'))).existsSync(),
      'JAVA_HOME_INVALID', 'JAVA_HOME does not contain bin/java: $javaHome');
}
