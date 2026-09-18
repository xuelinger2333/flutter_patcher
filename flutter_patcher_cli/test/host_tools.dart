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
