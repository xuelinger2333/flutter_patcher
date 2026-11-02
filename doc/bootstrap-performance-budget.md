# Bootstrap performance budget decision

Lean is the normal patch path: **85 ms**. Whole is the compatibility fallback
within the same authenticated baseline: **250 ms**. These are targets, not an
assertion that the current implementation meets them. Whole is not a fallback
across arbitrary Flutter/engine versions: fingerprint, version, signature and
interface constraints still apply. It is not a guarantee that every patch is safe.

The metric is elapsed wall time from BootRunner entry to the point immediately
before patched main, including native preparation, validation, module loading and
resource installation. It excludes log printing and patched main/UI work.
Android `am start TotalTime` and its difference from an unpatched app remain
separate diagnostics. A stopwatch overrun is an alert, never a reason to skip
integrity checks or to silently reject an otherwise valid patch.

The optional full performance run contains ten process-cold starts per tier with the established
three-second dwell and restart spacing. A performance verdict is green only if
all ten bootstrap samples are at or below its tier budget. Report distributions,
device/OS, artifact/source identity and measurement conditions. Do not relabel an
old failed performance record; analysis under this policy must state the policy.
Functional matrix success is independent of these performance verdicts.

Compact acceptance runs all 31 scenarios once for standard and
custom, without additional performance loops or redundant cold starts. It keeps
necessary activation, withdrawal and fault-recovery starts. Single observed
bootstrap timings are reported against lean 85 ms / whole 250 ms, not presented
as a ten-sample stability result.

Runtime policy lives in `lib/src/bootstrap/budget.dart`;
`analyze_bootstrap.py --assert-budget` checks both tiers. The `*_over_85ms`
fields are diagnostics only; use `bootstrap_over_budget` with
`bootstrap_budget_us` for the verdict.

## Scope and deferred work

- Preserve exact-byte native attestation and every validation constraint.
- Native dispatch, codec, thread and copy spans are reported (see
  `android/BOOTSTRAP_FFI.md`); measure them before changing scheduling.
- Whole framework reuse through a broader generated host interface is a separate
  compatibility design task and is out of scope for now.
  It requires safe class/interface identity, dependency/version boundaries,
  private/platform YAML generation and cross-version tests; it is not achieved
  by just retaining more libraries in whole-interface.yaml.
- Whole runtime frame/CPU/memory performance is still unmeasured. Larger bytecode
  coverage is reason to measure it, not evidence of a quantified runtime slowdown.
- Do not replace the exact-byte binding with trusting a pathname.

## Where archive checks run

Every check of a signed archive still runs at every boot; what moved is where
two of them run. Native reads the payload of the same snapshot it verified
with the rules of the Dart reader (`PatchArchive.readBytecode` on Android and
iOS) and checks each entry's ZIP CRC and the SHA-256 its manifest lists, with
the platform's CRC and SHA-256. The offer then carries `entries`: the envelope
offset and length of each entry it checked.

Dart still runs the complete ZIP, manifest, path, size and module checks. It
skips the CRC and digest of an entry only when its own reader selected that
entry at exactly the range native reported; any other entry, and any offer
without `entries` (the platform channel of an older host, for instance), gets
both checks in Dart. A difference between the two readers therefore costs a
check in Dart, never a check. `verifyPatchBytes`, for untrusted file bytes,
runs every check itself.

At boot, native identifies the stored file by the digest of its 146-byte
header, kept at install: the verified header pins the payload by digest, so
this pins the whole file the authorization named without hashing it twice.
Candidates installed before this field compare the file's digest.

## Hash scan experiment

The existing Dart path reads its file once. Three SHA-256 digests cover different
messages: payload, complete envelope and manifest entries. Feeding multiple
hashers from one chunk loop does not eliminate their independent compression
work. The module is only a subrange of the ZIP payload, not the same message.

A benchmark comparing sequential and interleaved
32-KiB chunk feeding of the three real whole-file ranges validated equal digests,
warmed up four rounds and alternated order over twelve measured rounds. A
Windows AOT run measured 38.283 versus 37.2345 ms median (about 2.7% difference).
This is host evidence, not an Android claim or a statistically established gain.
The experiment does not justify changing production verification ordering for
a predicted 46-ms saving. The production hash path is therefore unchanged.
