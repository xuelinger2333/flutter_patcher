import 'dart:io';

/// True when [tool] starts from PATH. Tests that need an external codec or
/// signer skip by tool presence, not by operating system.
bool hasTool(String tool, [List<String> args = const ['--version']]) {
  try {
    return Process.runSync(tool, args).exitCode == 0;
  } on ProcessException {
    return false;
  }
}

String? skipUnless(String tool) =>
    hasTool(tool) ? null : '$tool is not on PATH';

/// The Dart VM that runs bin/flutter_patcher.dart. Under `dart test` this is
/// the running executable; under `flutter test` it is flutter_tester in
/// `<flutter>/bin/cache/artifacts/engine/<platform>/`, beside the SDK's Dart in
/// `<flutter>/bin/cache/dart-sdk/bin/`.
final String dartVm = () {
  final self = Platform.resolvedExecutable;
  final name = self.split(RegExp(r'[\\/]')).last.toLowerCase();
  if (name == 'dart' || name == 'dart.exe') return self;
  final cache = File(self).parent.parent.parent.parent.path;
  return [
    cache,
    'dart-sdk',
    'bin',
    Platform.isWindows ? 'dart.exe' : 'dart',
  ].join(Platform.pathSeparator);
}();
