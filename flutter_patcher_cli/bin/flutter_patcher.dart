import 'dart:io';
import 'package:flutter_patcher_cli/src/cli.dart';

Future<void> main(List<String> arguments) async {
  exitCode = await runCli(arguments);
}
