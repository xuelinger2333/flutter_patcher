import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:path/path.dart' as p;

import '../core.dart';

/// Build-host identity.
///
/// A host is supported for the platforms it is verified to build and patch
/// for ([verifiedTargets]); `implemented` hosts have code paths, and any
/// pairing not yet verified is refused by the gate. Everything host-specific
/// (executable suffixes, the Flutter SDK toolchain directory, the gen_snapshot
/// artifact name) is derived here so the rest of the CLI never spells out
/// `linux-x64`.
class HostIdentity {
  /// `linux`, `windows` or `macos` (Dart's `Platform.operatingSystem`).
  final String os;

  /// `x64` or `arm64`.
  final String arch;
  const HostIdentity(this.os, this.arch);

  factory HostIdentity.current() => HostIdentity(
    Platform.operatingSystem,
    Abi.current().toString().split('_').last,
  );

  static const linuxX64 = HostIdentity('linux', 'x64');

  /// The platforms each host is verified for. An iOS patch compiles Dart
  /// only, so every verified host makes one; an iOS host build also needs
  /// Xcode, which `build ios` checks.
  static const verifiedTargets = {
    'linux-x64': {'android', 'ios'},
    'windows-x64': {'android', 'ios'},
    'macos-arm64': {'android', 'ios'},
  };
  static Set<String> get verified => verifiedTargets.keys.toSet();
  static const implemented = {'linux-x64', 'windows-x64', 'macos-arm64'};

  String get key => '$os-$arch';
  bool get isWindows => os == 'windows';
  bool get isPosix => !isWindows;

  /// Release-asset host name: `linux-x64`, `windows-x64`, `darwin-arm64`.
  String get assetHost => '${os == 'macos' ? 'darwin' : os}-$arch';

  /// Flutter SDK host toolchain directory. Flutter keeps macOS host tools in
  /// `darwin-x64` on every Mac; on Apple Silicon they are arm64 binaries.
  String get toolchainDir => os == 'macos' ? 'darwin-x64' : assetHost;

  String exe(String name) => isWindows ? '$name.exe' : name;
  String script(String name) => isWindows ? '$name.bat' : name;

  /// Engine release asset carrying this host's patched gen_snapshot.
  String get genSnapshotArtifact => exe('gen_snapshot-$assetHost');

  /// SDK-relative path of a host toolchain file such as
  /// `frontend_server_aot.dart.snapshot` or `font-subset`.
  String toolchain(String name) =>
      'bin/cache/artifacts/engine/$toolchainDir/$name';

  /// SDK-relative path where `flutter build apk` expects the AOT compiler.
  String get genSnapshotInstall =>
      'bin/cache/artifacts/engine/android-arm64-release/$toolchainDir/${exe('gen_snapshot')}';

  String flutterLauncher(String sdkRoot) =>
      p.join(sdkRoot, 'bin', script('flutter'));
  String dartBinary(String sdkRoot) =>
      p.join(sdkRoot, 'bin/cache/dart-sdk/bin', exe('dart'));
  String dartAotRuntime(String sdkRoot) =>
      p.join(sdkRoot, 'bin/cache/dart-sdk/bin', exe('dartaotruntime'));

  /// Rejects the first bytes of a gen_snapshot that is not a native
  /// executable for this host.
  bool isNativeExecutable(List<int> bytes) {
    if (bytes.length < 20) return false;
    switch (os) {
      case 'linux':
        return bytes.take(4).join(',') == '127,69,76,70' &&
            bytes[4] == 2 &&
            bytes[5] == 1 &&
            bytes[18] == (arch == 'arm64' ? 183 : 62) &&
            bytes[19] == 0;
      case 'windows':
        return bytes[0] == 0x4d && bytes[1] == 0x5a;
      case 'macos':
        return bytes.take(4).join(',') == '207,250,237,254';
    }
    return false;
  }

  @override
  String toString() => key;
}

/// Home directory for the managed cache. Windows has no `HOME`.
String? hostHome() =>
    Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];

/// The single host-support gate for every command. A command that builds
/// or patches for one platform passes it as [target]; other commands need a
/// host verified for any platform.
HostIdentity requireSupportedHost({
  String? target,
  HostIdentity? host,
  Map<String, String>? environment,
}) {
  final current = host ?? HostIdentity.current();
  final targets = HostIdentity.verifiedTargets[current.key] ?? const <String>{};
  final verified = target == null
      ? targets.isNotEmpty
      : targets.contains(target);
  // Maintainers bring up a new host, or platform, before it is verified.
  final unverified =
      (environment ??
              Platform.environment)['FLUTTER_PATCHER_UNVERIFIED_HOST'] ==
          '1' &&
      HostIdentity.implemented.contains(current.key);
  require(
    verified || unverified,
    'HOST_UNSUPPORTED',
    !HostIdentity.implemented.contains(current.key)
        ? 'Supported build hosts: ${HostIdentity.verified.join(', ')}; detected ${current.key}.'
        : targets.isEmpty
        ? 'Host ${current.key} is implemented but not yet verified for release.'
        : '$target on ${current.key} is not yet verified for release; '
              'this host is verified for ${(targets.toList()..sort()).join(', ')}.',
  );
  return current;
}

/// Marks a downloaded tool executable. No-op on Windows, where the loader
/// does not consult a mode bit.
Future<void> markExecutable(
  Commands commands,
  String path, {
  HostIdentity? host,
}) async {
  if ((host ?? HostIdentity.current()).isPosix) {
    await commands.run('chmod', ['755', path]);
  }
}
