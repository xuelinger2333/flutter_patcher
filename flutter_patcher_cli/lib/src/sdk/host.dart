import 'dart:ffi' show Abi;
import 'dart:io';
import 'package:path/path.dart' as p;
import '../core.dart';

/// Build-host identity.
///
/// `verified` hosts are supported; `implemented` hosts have code paths but
/// are not yet verified and are refused by the gate. Everything host-specific
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
      Platform.operatingSystem, Abi.current().toString().split('_').last);

  static const linuxX64 = HostIdentity('linux', 'x64');
  static const verified = {'linux-x64', 'windows-x64'};
  static const implemented = {'linux-x64', 'windows-x64', 'macos-arm64'};

  String get key => '$os-$arch';
  bool get isWindows => os == 'windows';
  bool get isPosix => !isWindows;

  /// Flutter SDK host toolchain directory: `linux-x64`, `windows-x64`,
  /// `darwin-arm64`.
  String get toolchainDir => '${os == 'macos' ? 'darwin' : os}-$arch';

  String exe(String name) => isWindows ? '$name.exe' : name;
  String script(String name) => isWindows ? '$name.bat' : name;

  /// Engine release asset carrying this host's patched gen_snapshot.
  String get genSnapshotArtifact => exe('gen_snapshot-$toolchainDir');

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

/// The single host-support gate for every command.
HostIdentity requireSupportedHost() {
  final host = HostIdentity.current();
  require(
      HostIdentity.verified.contains(host.key),
      'HOST_UNSUPPORTED',
      HostIdentity.implemented.contains(host.key)
          ? 'Host ${host.key} is implemented but not yet verified for release.'
          : 'Supported build hosts: ${HostIdentity.verified.join(', ')}; detected ${host.key}.');
  return host;
}

/// Marks a downloaded tool executable. No-op on Windows, where the loader
/// does not consult a mode bit.
Future<void> markExecutable(Commands commands, String path,
    {HostIdentity? host}) async {
  if ((host ?? HostIdentity.current()).isPosix) {
    await commands.run('chmod', ['755', path]);
  }
}
