# Authenticated bootstrap bytes implementation plan

Goal: remove path reopening and two redundant Dart SHA computations without
changing archive rejection or boot transaction semantics.
Spec: [approved design](authenticated-bootstrap-bytes-design.md).
Execution: inline in the current workspace, local commits only; no emulator,
phone configuration changes, push or publication. Primary agent uses gpu builds.

- [x] Transport and parser: `BytecodePatchManager.kt` returns
  `transportVersion: 1, envelopeBytes: ByteArray, attempt`; `runner.dart` rejects
  legacy replies and calls `parseAuthenticatedPatchBytes(Uint8List, String)`.
  `verifyPatchBytes` remains the offline exact-file verifier. Shared archive
  parsing retains all CRC, manifest and entry checks. Remove BootRunner.read.
- [x] Tests: adapt startup fixtures, exercise wrong response types/version,
  expired attempt and late response; codec preserves 2 MiB bytes even after
  original array changes. Keep offline corruption tests.
- [x] Profiles: schema 2 explicitly identifies native-bytes transport and
  absent file-read/payload-SHA/file-SHA work. Analyzer supports schema 1 and 2,
  rejects missing schema-2 counters and reconciles every measured interval.
- [ ] Test-only probe: generated acceptance Android/Dart sources run paired
  pre-bootstrap and post-frame empty/byte/verified-byte requests with matched
  worker/main response path, request IDs and no boot transaction mutations.
  Keep probes disabled during the formal matrix and report memory observations.
- [ ] Validate locally with Flutter bootstrap/CRC tests and Python contracts;
  rebuild using `test/acceptance/rebuild_regression.py --config
  test/acceptance/regression-config.example.json`. Require native JVM tests,
  instrumentation 4/4 and matrix 31/31. Run analyzer with `--assert-budget`.
- [ ] Preserve raw receipts, write measured report, update SPEC/README, commit
  locally. If whole still exceeds 200 ms, report the gap without changing the
  agreed archive checks or starting the native entry-parser redesign.
