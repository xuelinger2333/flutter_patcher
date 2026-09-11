# CRC optimization, tier budgets and channel tracing — 2026-09-11

## Implemented

- Replace ZIP's bit-at-a-time CRC with an equivalent 256-entry IEEE CRC-32 table.
  Keep validation order, ZIP constraints, signature and all SHA-256 checks.
- Use separate absolute bootstrap budgets: lean 85 ms, whole 200 ms. Update the
  local SPEC and tracked [budget decision](../../doc/bootstrap-performance-budget.md),
  runtime warnings, matrix metadata and offline performance assertion.
- Add monotonic measurements around Android method-codec decoding, handler
  preparation, worker creation/scheduling, the operation, main-thread reply queue,
  response encoding and reply send. Record lock wait and Dart codec time separately.
  StandardMethodCodec remains responsible for the wire representation. No thread
  scheduling strategy, host interface or native hash binding was changed.

Native channel intervals overlap the existing native function span. The analyzer
reconciles each channel trace independently and does not add it again to the main
bootstrap breakdown. Time outside the measured Java channel remains a residual;
these probes cannot by themselves distinguish engine inbound and outbound queues.

## Checksum experiments

The table implementation passes the standard `123456789` CRC, empty input and
independent zlib fixtures including 2 MiB and typed-data subviews.
A local Windows Dart AOT experiment (four warm-up rounds, twelve alternating
measured rounds) measured 2 MiB at 62.6175 ms median for the previous bit loop
and 5.9595 ms for the table. This is host evidence, not a phone measurement.
Raw results: `.dart_tool/flutter_patcher/crc-benchmark.json`.

The three-hasher interleaving experiment used the actual whole FPTC ranges and
verified all three digests. Sequential and interleaved medians were 38.283 and
37.2345 ms, with substantial variation. Interleaving still performs all three
SHA compression computations; it also cannot equate the module and ZIP digests,
which cover different byte sequences. This does not justify production complexity
or a claim of eliminating two-thirds of SHA time. Production hashing is unchanged.
Raw results: `.dart_tool/flutter_patcher/hash-scan-benchmark.json`.
Reproducible experiment source: `hash_scan_benchmark.dart` (compile to AOT first).

## Build and remaining validation

Current-source rebuild directory:
`.dart_tool/flutter_patcher/regression/20260911-211603-17ea060d/`.
The isolated gpu builder regenerated the APK, lean/whole patches, 31-case corpus,
native tests and instrumentation APK. Existing device results from earlier
implementations are not evidence for this version.

Local Dart tests: 13/13. Python contract tests: 5/5. JVM tests: 32/32 passed,
including both new codec compatibility tests. Device measurements and the
current-version 4-test instrumentation / 31-case matrix remain pending because
ADB lists no connected device. No phone configuration changes, emulator, push
or publication were used. No claim is made that whole now meets 200 ms.

The top-level result is `failed` at instrumentation installation with
`device 'AF2Q025C05004551' not found`; `inputs/build-result.json` is `passed`.
This is retained as a device-availability failure, not a product test verdict.
APK size is 24,952,882 bytes. Frozen source SHA256:
`10f1d03975d3a8e216e8ef95b4ae90d39d5039da9df1b2705952bc2f5c7ec76b`.

After reconnecting, resume the frozen build into a new result directory:

```powershell
python test/acceptance/rebuild_regression.py --config test/acceptance/regression-config.example.json --resume-built .dart_tool/flutter_patcher/regression/20260911-211603-17ea060d
```

Use the bundled Python path documented in README if `python` is a Store alias.
Then run `analyze_bootstrap.py --run NEW_RUN --out NEW_RUN/bootstrap-analysis.json
--assert-budget`. Report both tier verdicts and channel spans. If product source
changes before testing, rebuild instead of using this frozen build.

Framework reuse through the whole host interface is explicitly deferred until
after M1.5. Moving hash work to Android and profiling whole runtime frame/CPU
behavior remain distinct follow-up work, not changes hidden in this optimization.
