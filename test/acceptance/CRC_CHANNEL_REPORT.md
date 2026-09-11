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
including both new codec compatibility tests. At this initial checkpoint, device
measurements and the current-version instrumentation / matrix were pending because
ADB listed no connected device. See the device follow-up below. No phone configuration changes, emulator, push
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

## Device follow-up: 2026-09-11 21:38

The same frozen build was resumed into the fresh directory
`.dart_tool/flutter_patcher/regression/20260911-213838-f4da09a3/` after reconnection.
Device: HONOR MEY-AN00, Android 16/API 36, serial AF2Q025C05004551. Ten process-cold
starts per tier, retaining the established three-second spacing and dwell.

| Bootstrap metric | Lean | Whole |
| --- | ---: | ---: |
| Mean | 65.14 ms | 252.63 ms |
| Median | 65.02 ms | 252.53 ms |
| Minimum | 53.39 ms | 244.97 ms |
| Maximum | 73.48 ms | 262.48 ms |
| Tier budget | 85 ms | 200 ms |
| Samples within budget | 10/10 | 0/10 |

Whole CRC now averages **15.86 ms**, versus **71.67 ms** in the preceding
instrumented run (`20260911-204739-e9958ac8`): about 78% lower, but not single-digit
milliseconds on this phone. Whole bootstrap mean changed from 316.79 to 252.63 ms
(about 20% lower). These are successive same-device runs, not randomized A/B
measurements; the stage-specific CRC change is stronger evidence than attributing
every millisecond of total-time change to CRC.

Whole still spends 68.19 ms in the three Dart SHA-256 passes, 88.18 ms loading the
module, and 10.18 ms in markBooting. Native envelope verification including
Ed25519 is 16.28 ms. Eliminating the remaining CRC time entirely would still leave
about 236.77 ms, so CRC alone cannot meet the 200 ms whole target.

The Android total-start-time medians are 500 ms patched and 274 ms original,
a 226 ms difference. This is separate from the bootstrap budget metric above.

### Native channel decomposition

Means in ms. Rows within Java reconcile to Java total; this table overlaps the
bootstrap's native span and must not be added to it a second time.

| Span | Lean | Whole |
| --- | ---: | ---: |
| Java decode | 0.051 | 0.052 |
| Handler preparation | 0.061 | 0.060 |
| Worker creation / scheduling | 0.410 | 0.401 |
| Native operation | 15.705 | 26.083 |
| Main-thread reply queue | 3.527 | 3.893 |
| Java reply encoding | 0.136 | 0.111 |
| Reply send and surrounding work | 0.070 | 0.065 |
| **Measured Java channel total** | **19.960** | **30.665** |
| **Payload interval outside measured Java channel** | **35.708** | **36.096** |

Lock wait reads 0 microseconds in all samples (microsecond reporting resolution,
not proof of mathematically zero wait). Dart request encoding plus response
decoding averages 0.117 ms lean and 0.091 ms whole. Main-thread reply queue maxima
are 7.46/7.71 ms, so it does not explain the roughly 36 ms residual.

This narrows the fixed cost: plugin locking, worker startup and codec work are
not its main source. The residual lies mostly outside the instrumented Java
decode-to-reply boundary and remains similar for both tiers. It includes engine /
platform dispatch and Dart callback delivery, plus small unmeasured call setup.
These measurements do not distinguish inbound from outbound engine queues or
prove a particular Android startup scheduling cause. Further attribution needs
engine message-boundary tracing or a correlated system trace, not another guess
that the plugin's main-thread post accounts for all of it.

### Final validation and receipts

The resumed run completed with process exit 0 and top-level status `passed` /
stage `complete`. Instrumentation passed 4/4. The fault matrix passed 31/31,
with all case IDs and their order matching the fresh corpus, and no failed cases.
No cases were skipped or assembled from prior runs. The earlier disconnected
device result remains preserved.

The separate performance assertion exited 1 with
`BOOTSTRAP_OVER_BUDGET: whole`: functional acceptance passed, while the whole
200 ms performance target did not. All 20 detailed profiles reconcile with the
broad stage timings and include matching native channel traces.

All files listed in the frozen source manifest still match their SHA256 except
`test/acceptance/README.md`, whose documentation was updated after the build.
Product and test harness sources match the tested build. The source manifest's
base commit predates the implementation commit `994f77c`; file hashes identify
the actual tested content. This report was added separately from that manifest.

Receipts under `.dart_tool/flutter_patcher/regression/20260911-213838-f4da09a3/`:

| File | SHA256 |
| --- | --- |
| `result.json` | `2c0cc84c167f8965f569babb82bdd9104553469a1c1d1af635d1ccc1bc3fe8d3` |
| `matrix/result.json` | `f348ec48f1585326cd7d1eb0a669eec25dda5dcff0a16dc4c61ef15a37e77f74` |
| `bootstrap-analysis.json` | `ccaa19145bef129cbbec604d898f0f939033aa13c44456027bdf7e6709a70f03` |
