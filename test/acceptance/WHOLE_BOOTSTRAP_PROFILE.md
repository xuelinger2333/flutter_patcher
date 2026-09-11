# Whole bootstrap diagnosis — 2026-09-11

The slowdown has two main sources: repeated full-data validation in Dart and
loading a much larger dynamic module. It is not mainly Ed25519, resource
installation, or application main/UI work.

## Measurement

HONOR MEY-AN00, Android 16/API 36, arm64. Ten independent process starts per tier,
with three-second first-frame dwell and three-second stop-to-start spacing.
These are wall-clock spans, not exclusive CPU samples or storage-cache-cold boots.
The bootstrap stopwatch stops before patched main and before printing the profile.
Native intervals use System.nanoTime; Dart intervals use Stopwatch.

The instrumented source was rebuilt into a new APK and new corpus in
`.dart_tool/flutter_patcher/regression/20260911-202911-bf887933/`.
That attempt stopped at an Android installation rejection. After the user allowed
installation, its verified frozen build was tested in the new directory
`.dart_tool/flutter_patcher/regression/20260911-204739-e9958ac8/`.
The failed attempt remains intact. No device settings were changed.

## Measured stages

Means in milliseconds; percentages use mean whole bootstrap, not Android's
am-start total-time difference. All twenty samples reconcile exactly to total.
Nested CRC and entry-digest counters are subtracted from their enclosing spans
before computing the additive breakdown.

| Stage | Lean mean | Whole mean | Whole share |
| --- | ---: | ---: | ---: |
| Native bootPayload plus dispatch/return | 60.81 | 70.53 | 22.26% |
| Dart file read and verification | 2.10 | 145.09 | 45.80% |
| markBooting, observation and module load | 8.01 | 100.91 | 31.85% |
| Entry validation and resources | 0.25 | 0.26 | 0.08% |
| **Bootstrap total** | **71.17** | **316.79** | **100%** |

The whole median is 315.32 ms; range 307.67–331.86 ms. Inside those stages:

| Substage | Lean mean | Whole mean | Whole share |
| --- | ---: | ---: | ---: |
| Dart ZIP CRC | 0.35 | 71.67 | 22.62% |
| Dart payload SHA-256 | 0.20 | 23.60 | 7.45% |
| Dart complete-file SHA-256 | 0.13 | 22.92 | 7.23% |
| Dart entry SHA-256, predominantly module.bc | 0.11 | 22.89 | 7.23% |
| VM loadDynamicModule and entry return | 0.45 | 90.63 | 28.61% |
| markBooting round trip and durable state commit | 7.55 | 10.28 | 3.24% |
| Native envelope verification, including Ed25519 | 11.92 | 16.36 | 5.16% |
| Native file read | 0.24 | 6.21 | 1.96% |
| Dart file read, including payload-field handling | 1.13 | 3.79 | 1.20% |

The remaining native call interval outside the measured native function averages
42.31 ms whole versus 43.91 ms lean. This includes dispatch, scheduling, lock wait,
return creation/encoding and channel handling; it is **not** a measurement of
just serialization or a proven single Android scheduling delay. Native preparation,
complete-file digest and offer creation account for the rest of native time.

## Why whole grows

1. The actual `module.bc` grows from 8,628 to 2,170,998 bytes (about 252 times).
   Both archives contain only five entries, and font/asset sizes remain tiny.
   The compiler reports 3 libraries for lean and 526 for whole, including 454
   Flutter libraries. This count describes the compiler report, not the number
   of functions executed during boot. `pipeline.dart` constructs whole's host
   interface from `dart:` libraries only, so framework/dependency code is carried
   inside the module rather than reused through the lean host interface.
2. `patch_archive.dart` computes CRC with an eight-iteration bit loop for every
   byte: roughly 17.4 million inner steps for the whole module. Both ZIP central
   and local metadata are validated, but the CRC loop dominates ZIP time:
   71.67 ms, while other ZIP parsing takes about 0.05 ms. STORED ZIP entries are
   not decompressed, so this is not decompression cost.
3. Dart SHA-256 scans the payload, the complete signed file, and each manifest
   entry. Because module.bc dominates the archive, about 6.5 MB are hashed across
   these three passes, taking 69.41 ms combined. The complete-file hash binds the
   Dart-read bytes to native authentication and prevents path replacement from
   bypassing verification. Native authentication is a separate earlier stage.
4. The measured `loadDynamicModule` boundary grows from 0.45 to 90.63 ms.
   markBooting is separately measured, so this is not just its durable commit.
   The generated module entry returns a six-element contract with function
   references; patched main has not run. VM-internal parsing, linking, class
   materialization and entry execution were not individually profiled, so this
   report does not assign percentages to those internal activities.

CRC, the three Dart digests and VM loading explain about **94%** of the measured
whole-minus-lean increase of 245.62 ms. Ed25519 is not the main explanation.

## Comparison limits and next experiments

The prior uninstrumented Kotlin run (`20260911-195036-57fb6769`) measured whole
bootstrap mean 285.07 ms and lean 65.53 ms. The instrumented run is about 11%
higher for whole; there was no controlled alternating A/B experiment or fixed
CPU-frequency/thermal setup. Do not label the entire difference as logging
overhead or a product regression. Both runs show the same dominant broad stages.
The previous 244 ms figure was the median Android start-time increase; this run's
Android medians are 571.5 ms patched and 295 ms original (276.5 ms difference).
Those are distinct from the bootstrap stopwatch and should not be mixed.

Recommended order, without removing validation or changing behavior in this run:

1. Replace the bit-at-a-time CRC with an equivalent table-based implementation.
   Reuse malformed-archive cases and checksum vectors; measure the same stages.
   The measured 71.67 ms is an upper bound on the saving, not a promised speedup.
2. Optimize SHA-256 execution and full-buffer scanning. Preserve exact-byte
   native attestation and every manifest integrity constraint; do not simply
   remove the complete-file check or trust a path after verification.
3. Reduce safely bundled whole-module code, then profile inside the engine if
   necessary. Reusing framework code requires interface/compatibility work,
   not merely deleting libraries from a compiled module.
4. Separately trace the fixed native call/dispatch cost if targeting the 85 ms
   budget. The nearly identical lean/whole residual is not the source of the
   size-dependent increase, but it consumes a large fixed part of that budget.

Even making the entire 145.09 ms Dart verification phase free would leave about
171.70 ms in this run. Thus a checksum-only optimization cannot reach 85 ms.
No performance fix is claimed here; this change adds measurement and analysis.

## Reproduce the analysis

```powershell
python test/acceptance/analyze_bootstrap.py --run .dart_tool/flutter_patcher/regression/20260911-204739-e9958ac8 --out .dart_tool/flutter_patcher/bootstrap-profile-analysis.json
```

Add `--assert-budget` to fail if any whole bootstrap sample exceeds 85 ms.
The analysis joins each profile to exactly one recorded sample using its full
stage tuple and tier, retains the PID, and rejects missing/ambiguous or
non-reconciling measurements. The input log's byte hash is recorded.
For a build without detailed counters, it still summarizes the four broad stages.
The JSON preserves all raw profiles and per-stage mean/median/min/max.

## Validation and receipts

- Functional matrix: 31/31 passed, exact corpus order, no failures or skips.
- Android instrumentation: 4/4 passed; JVM methods: 30/30 passed.
- Targeted Dart bootstrap tests: 12/12 passed; `git diff --check` passed.
- The analysis budget assertion exits 1 with `WHOLE_BOOTSTRAP_OVER_85MS`, as
  expected for the still-unfixed performance issue. Functional success does not
  turn this performance verdict green.
- All three instrumented product source files match the rebuilt source receipt.
  The analyzer and report were added after the frozen build.

Source SHA256:
`d9e4043f065e4b76b5ff2a3a02b66263b02034393a67d91bcd999240269ffde6`.
The final device run's `result.json` SHA256:
`81df79d24eb941863f91211577f915d7dd9457646c9da10666b90d065ec9dc20`.
The final `bootstrap-analysis.json` in the same directory has SHA256:
`19da163257544d4bfffea2c957bd0915d3602659a480e7609c3f13eef37d6294`.
