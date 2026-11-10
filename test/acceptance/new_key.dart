// Writes a new patch key bundle to the new file named by the argument and
// prints its public key: the device acceptance signs with one key file, as
// a CI job does.
import 'dart:io';

import 'package:flutter_patcher/src/cli/keys/bundle.dart';

Future<void> main(List<String> args) async {
  final bundle = KeyBundle.generate();
  await writeNewKeyFile(args.single, bundle.encode());
  stdout.writeln(bundle.publicKey);
}
