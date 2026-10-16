import 'dart:async';

import '../../bin/mock_server.dart' as mock_server;

Future<int> main(List<String> args) {
  // Positional-argument wrapper around bin/mock_server.dart.
  return mock_server.main([
    '--dist',
    if (args.isNotEmpty) args[0] else 'dist',
    if (args.length > 1) ...['--port', args[1]],
  ]);
}
