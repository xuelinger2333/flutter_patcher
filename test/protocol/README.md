# FPTC v1 vectors

`fptc-v1.json` holds patch files and the verdict every verifier must reach:
the CLI (`test/cli/fptc_test.dart`, `test/cli/ed25519_test.dart`), Android
(`FptcVectorsTest`) and iOS (`test/ios/run.sh`). The files are assembled byte
by byte from the format, not by the CLI's sealing code.

Regenerate from the repository root:

```text
dart run test/protocol/generate_fptc_vectors.dart
```

The seeds are the public RFC 8032 test seeds. Never sign real patches with them.

`files` lists a file, the host it is checked against (`fingerprint`, and
`host_key`, null for a host that takes unsigned files) and whether that host
accepts it, with its `seq` and `action` (`publish`, or `withdraw` for a file
without payload). A rejected file names the `reason` a verifier finds first.
Sequence rules (newer than what a device accepted) are device state, tested
apart. `file_names` gives the name a host's files go by.

Android reads the vectors from the repository; set
`FLUTTER_PATCHER_FPTC_VECTORS` to an absolute path when the test host is
outside it.
