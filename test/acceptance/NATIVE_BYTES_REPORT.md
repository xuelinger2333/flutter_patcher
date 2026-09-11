# Native authenticated-byte bootstrap — 2026-09-11

Implementation commit: `e009aee`. Standalone experiment sources: `4e30441`.
Design: [authenticated byte transport](../../doc/authenticated-bootstrap-bytes-design.md).

## Change under test

Android returns the same local ByteArray that passed envelope authentication and
the stored-candidate digest check. Dart accepts only transportVersion 1 plus a
Uint8List and nonempty attempt. It no longer reopens a path or computes the
payload/full-file SHA again. Archive CRC, manifest entry digests, identity checks,
entry contract and boot transaction state remain unchanged.

The offline file verifier still performs both hashes. Profile schema 2 makes
removed work explicit without interpreting missing mandatory counters as zero.
The local SPEC was updated; it is ignored by Git, so the tracked design and this
report preserve the protocol change too.

## Local validation

- 36 Dart tests passed: bootstrap behavior, typed-data snapshot surviving source
  file replacement/array mutation after codec encoding, old protocol and bad
  response rejection, expired attempt and late response, CRC fixtures, binding
  ownership and the archive/entry subset of the previously authenticated corpus.
  The reused corpus is unit-test input, not current-build device evidence.
- Six Python checks passed, including profile schema and budget boundaries.
- Static analysis found no errors/warnings in inspected code; style infos remain.
- Historical schema-1 analysis still reproduces the previous 65.144/252.631 ms
  bootstrap means. No old result file was overwritten.

## Frozen rebuild

Run: `.dart_tool/flutter_patcher/regression/20260911-221130-cc74ea2d/`.
Source SHA256: `2bfd64c1a3c7b885d3500ac3b8cf9b62bddf29655a5dbfbb1898ce3bcfcd7b22`.
Build passed: JVM 33/33, zero failures/errors/skips; APK 24,952,882 bytes.
Output archive SHA256:
`8eed07fbd120d1674f2690ea2a209306211504b1edacb38b4bfed07e937fdb1a`.
The origin run failed during an interrupted SCP download. That result and partial
archive were preserved. Re-download matched the remote checksum. Resume
`20260911-222945-0742bb46` failed when the phone rejected instrumentation install;
that record is preserved too. Neither is a product-test verdict.

Fresh device run: `20260911-223038-c59699d8`, same frozen build, instrumentation
4/4 passed. The complete matrix passed 31/31 with process exit 0, top-level
`passed` / `complete`, and exact case IDs/order matching the fresh corpus.
No cases were skipped or combined from prior runs. Every product and execution
harness file in the frozen manifest still matches locally; only documentation
changed afterward. Probe files were added
separately and were not part of the formal device build.

## Device bootstrap results

HONOR MEY-AN00, Android 16/API 36, arm64; ten process-cold samples per tier.

| Bootstrap | Lean | Whole |
| --- | ---: | ---: |
| Mean | 65.343 ms | 205.861 ms |
| Median | 65.834 ms | 204.609 ms |
| Minimum | 54.382 ms | 202.032 ms |
| Maximum | 73.692 ms | 213.255 ms |
| Budget | 85 ms | 200 ms |
| Samples within budget | 10/10 | 0/10 |

Whole mean fell from 252.631 to 205.861 ms (46.770 ms, 18.5%). The previous
bit-CRC implementation was 316.794 ms; successive optimizations now save about
110.933 ms overall. These are sequential same-device runs, not randomized A/B.
Lean remains essentially unchanged at 65.343 versus 65.144 ms.

Whole Dart verification fell from 87.239 to 38.862 ms. It now consists mostly of
15.992 ms CRC and 22.638 ms entry SHA. Native payload time rose from 66.761 to
70.553 ms, while load/handshake changed from 98.361 to 96.170 ms. Module load alone
is still 88.424 ms; markBooting is 7.743 ms. The residual outside Java remains
36.762 ms (previously 36.096 ms).

Java success-envelope encoding now averages 2.142 ms for whole, versus 0.111 ms
with the old small path response. Dart decoding averages 0.062 ms, versus
0.054 ms. These counters do not capture all engine copy/queue work. The total
native-payload increase is not attributable solely to serialization.

All twenty schema-2 profiles reconcile with their broad timing and matched native
traces. The independent budget assertion reports `BOOTSTRAP_OVER_BUDGET: whole`.
The whole mean exceeds budget by 5.861 ms; the slowest sampled launch exceeds it
by 13.255 ms. Being close is not passing, and entry SHA/CRC checks were not removed
to obtain a green performance verdict.

Android total-start medians are 289.5 vs 276 ms for lean/original, and 456 vs
273 ms for whole/original. These are separate end-to-end observations, not the
absolute bootstrap metric or proof about all other startup costs.

## Probe interpretation limits

The separate test APK reproduces the same codec, worker/main reply pattern and
frozen envelope verifier; it never resets processClaimed or mutates patch state.
It compares pre-binding and post-frame calls with empty, byte and verified-byte
responses. It uses an ordinary app entry, without the full production host's
initialization and module loading, so it is a phase-sensitivity experiment, not
an exact replay of the production bootPayload transaction.

Payload read in this probe is from a packaged asset; native operation time also
includes that read and, for verified mode, test metadata parsing. Compare the
outside-Java residual as well as total latency; total validation work is not
expected to vanish after the first frame. First verification also includes lazy
crypto initialization. Dart verifies returned byte digests outside the timed span.

RSS and high-water RSS include the process, framework and post-timing digest
work; they are not isolated codec allocation measurements. The single ~2 MB
payload does not establish safe near-limit 320 MiB transfers or a worst-case
memory bound. No transport limit was silently changed.

## Completed cold/post-frame experiment

Probe APK SHA256: `fb4c76a1648045fe91e373061f963da206cd5da7fb5fa20f77a2f2506cad0da6`.
Its `libflutter.so` matches the downloaded formal APK exactly:
`48ad521ae7a4bee35c164a4fdf647d77ee2f385d60544698920a7aaced535011`.
The copied native source hashes and all build templates matched the build receipt.
The fixed FPTC envelope is 2,174,015 bytes, from this run's valid-whole corpus.

The runner exited 0 after 30 launches / 60 samples, ten paired observations per
workload. All returned bytes, request IDs, phase pairs, counter sums and
same-process post-frame dwell checks passed. No startup state machine was reset.

Means in milliseconds:

| Workload | Cold round trip | Post-frame round trip | Cold outside-Java residual | Post-frame outside-Java residual |
| --- | ---: | ---: | ---: | ---: |
| Empty | 36.340 | 1.609 | 34.904 | 0.615 |
| Whole-sized bytes | 54.987 | 22.923 | 34.004 | 1.314 |
| Verified whole-sized bytes | 71.403 | 36.664 | 34.819 | 0.889 |

The phase effect appears with all three payloads. Even the empty response has
about 35 ms residual before binding creation, shrinking below 1 ms after the
first frame. This supports startup-phase sensitivity in the channel/engine
delivery path; signature work and transferring 2 MB cannot explain that fixed
residual. It does not isolate inbound versus outbound dispatch, a particular
platform-thread task, Surface creation, or prove FFI is the right replacement.

Full post-frame verified round trips remain about 36.7 ms because the native
operation itself averages 33.1 ms here (asset read, metadata read, verification
and candidate hash). That is why comparing only total RTT to a few milliseconds
would give the wrong conclusion. A real engine-boundary trace is still needed
if that attribution is pursued; no FFI or production scheduling change was made.

Post-frame process RSS means are 198.8 MiB empty, 217.9 MiB bytes, and 234.2 MiB
verified bytes. The largest observed process high-water RSS is 235.6 MiB. These
figures include different crypto/Flutter initialization and two calls per process;
their differences are not an isolated copy-allocation estimate.

Probe data is under `.dart_tool/flutter_patcher/channel-probe/20260911-native-bytes/`.
`device/result.json` SHA256:
`c0fe5c3748813f38fd8018c1a550ef9dbefe27658c64a8b194eba94059b3ba2d`.
The receipt includes the runner hash; logs and per-launch meminfo are retained.
The formal acceptance APK was restored after the experiment. The installed
base.apk hash was read back from the phone and matched
`f28d9359c54827279187f0d4f8a800580853a58fdefe26e59a96b353ef30fcb9`.

## Remaining performance decision

This approved step is complete: exact-byte transport is implemented, redundant
Dart hashes are removed, functional regression is green, and the phase probe is
measured. Whole still fails the 200 ms gate in all ten formal samples. The next
candidate is the remaining 22.6 ms entry digest computation, with its consistency
contract preserved; moving that validation boundary requires the separate design
identified in the security document. CRC is about 16 ms and module load about
88 ms. This run does not weaken checks, alter budgets or expand into the deferred
host-interface/FFI work to label the result passing. Custom-binding matrix,
keys init and maximum-size transport validation remain outside this experiment.

## Formal regression receipts

Under `.dart_tool/flutter_patcher/regression/20260911-223038-c59699d8/`:

| File | SHA256 |
| --- | --- |
| `result.json` | `bce7768b6854f129a7834895f66c147b705273f294be4f35be22a020384f3fe0` |
| `matrix/result.json` | `88496d8a5fdb7e50d86342323e8dcba605bc173a096bc58b4040b7c845c76ae2` |
| `bootstrap-analysis.json` | `4cc26b0cd336e5c091302c957ee96e0f3cfd5ddaed3c8a2e69c75320a1a8fd92` |
