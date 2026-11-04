import 'dart:io';

import 'package:flutter_patcher/src/cli/cli.dart';

Future<void> main(List<String> arguments) async {
  exitCode = await runCli(arguments);
}
