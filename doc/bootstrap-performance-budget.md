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

- Implement equivalent table-based CRC and measure checksum alternatives.
- Preserve exact-byte native attestation and all validation ordering/constraints.
- Split native dispatch/codec/thread/lock/return spans before changing scheduling.
- Whole framework reuse through a broader generated host interface is a separate
  compatibility design task and is out of scope for now.
  It requires safe class/interface identity, dependency/version boundaries,
  private/platform YAML generation and cross-version tests; it is not achieved
  by just retaining more libraries in whole-interface.yaml.
- Whole runtime frame/CPU/memory performance is still unmeasured. Larger bytecode
  coverage is reason to measure it, not evidence of a quantified runtime slowdown.
- Moving hashes to Android needs a separate design for binding the exact bytes
  consumed by Dart. Do not replace that binding with trusting a pathname.

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
