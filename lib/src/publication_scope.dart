import 'dart:convert';

import 'package:crypto/crypto.dart';

/// Names a host's publications. `publish` writes the signed head of a scope
/// to `manifests/<scope>.json`, and a host computes the same name from the
/// scope built into it, so devices find their manifest by convention.
String scopeOf(Map<String, String> fields) => sha256
    .convert(
      utf8.encode(
        jsonEncode({
          for (final k in const [
            'application_id',
            'channel',
            'flavor',
            'version_code',
            'abi',
            'fingerprint',
            'strategy',
          ])
            k: fields[k],
        }),
      ),
    )
    .toString();
