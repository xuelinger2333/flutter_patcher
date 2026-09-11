# Real-device fault matrix

## Rebuild current product sources and regress

```powershell
python test/acceptance/rebuild_regression.py --config test/acceptance/regression-config.example.json
```

The example is configured for the existing `gpu` Linux builder and HONOR test
device. Copy it to an ignored local file to use another environment. This command
uses SSH/SCP for isolated builds only; it does not push Git, publish releases,
alter phone settings or launch emulators. Python 3.12+ is required for safe archive
extraction, along with the configured Linux Flutter/Android SDK, Python test
dependencies, and fixed artifact/generator files. Installation can require normal
on-device approval.

The command snapshots current tracked and non-ignored untracked files (including
uncommitted product changes), hashes their bytes, and transfers that snapshot to
a new remote directory. Keep secrets and local configuration Git-ignored. Both
build and patch use that same frozen snapshot. The recorded commit identifies
the base; `source_sha256` identifies the actual source being tested. The command
rebuilds the APK, lean/whole patches and all 31 matching fault samples, runs native
tests, builds/runs the 4 instrumentation tests, then runs the real-device matrix.

The timestamped `.dart_tool/flutter_patcher/regression/` output contains a top-level
`result.json`, APK byte size, source receipt, `instrumentation.txt`, downloaded
build evidence and `matrix/result.json`. Every failed stage exits nonzero and
keeps its evidence; old outputs are not reused as current results. Local source
changes after snapshot creation belong to the next run. This is a same-builder
regression, not independent-host M1 acceptance.

If the device disconnects after a successful build, reconnect it and add
`--resume-built PATH_TO_PRIOR_RUN` to the same command. This verifies and extracts
the previous output archive into a **new** result directory and reruns device
tests. The report explicitly says `resume_frozen_build`; it tests the old frozen
source, never claims to test later product edits. The failed attempt stays intact.
Omit this flag whenever product code changed and a fresh build is required.

On this Windows workstation, if `python` points to the Microsoft Store alias,
use the bundled interpreter without changing PATH:

```powershell
& "$env:USERPROFILE/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/python.exe" test/acceptance/rebuild_regression.py --config test/acceptance/regression-config.example.json
```

## Rerun an already built APK and corpus

Use Python 3, ADB, Dart and an unlocked API 33+ arm64 device. The dedicated
`com.example.wp9_acceptance` APK is installed and its data is reset between cases.
If the installed base APK has exactly the requested SHA256, installation is
reused; a changed APK still requires installation. This is recorded in the result.
This command does not change battery/startup settings or start an emulator.

```powershell
python test/acceptance/run_matrix.py --inputs .dart_tool/flutter_patcher/ed25519-fix/standard-inputs --serial AF2Q025C05004551 --dart D:/DevTools/flutter/bin/cache/dart-sdk/bin/dart.exe
```

Replace `--inputs` with the extracted matching acceptance bundle. It must contain
`standard-build/handoff.json`, `standard-build/release/app-release.apk`, and
`standard-corpus/` with its 31-case `corpus.json`. Use `--binding custom` for the
equivalent `custom-build`/`custom-corpus` layout. The archived input tests that APK;
after product changes rebuild the APK and matching corpus before regression.

The default output is a fresh timestamped `.dart_tool/flutter_patcher/matrix/`
directory. Use `--out PATH` to choose another fresh directory. The process exits
nonzero on failure; successful completion requires all 31 cases. `result.json`
and the CI-compatible `device.json` contain the final verdict. Existing results
are never overwritten. Preflight input errors exit before touching the device.

Each first frame is followed by a three-second dwell and a same-process liveness
check. Controlled cold starts then force-stop and wait three seconds. Startup
timing excludes dwell. `lifecycle.jsonl` records deliberate stops;
`live-logcat.txt` continuously preserves runtime evidence independently of the
phone's ring-buffer retention. Per-process timing is scoped to the startup time
to exclude old records when Android reuses a PID.

The hang case occupies the main thread, so a queued `am crash` may never execute.
It instead sends a space key to the focused test app, uses a temporary package-
filtered `am monitor -k` to terminate the resulting input ANR, and verifies the
exact PID's Android ANR exit record before restarting. The monitor is closed in
all outcomes. The default one-failure circuit breaker must recover original code
and reject the quarantined patch on reinstallation.

The suite covers valid lean/whole controls, envelope/signature rejection,
sequence replay, archive/entry rejection and crash/hang quarantine. Timing
budget alerts remain separate: a passing functional matrix does not prove the
tier-specific startup budgets, cross-machine acceptance, or complete M1 readiness.
Do not interact with the test app during the run. Installation may require the
phone's normal confirmation. No automatic retries or skipped cases are used.

## Bootstrap stage profiling

New builds emit `BYTECODE_BOOT_PROFILE` alongside the existing total timing.
It separates native preparation/read/verification, Dart file read, SHA-256,
ZIP CRC, durable boot handshake and dynamic-module loading. Nested counters are
not additive until their enclosing spans have been adjusted.

Use `python test/acceptance/analyze_bootstrap.py --run PATH_TO_REGRESSION_RUN
--out PATH_TO_ANALYSIS_JSON` to join profiles to the exact twenty sampled cold
starts and summarize durations and shares. Add `--assert-budget` to return
nonzero when lean bootstrap exceeds 85 ms or whole exceeds 200 ms in any sampled
startup. This uses absolute bootstrap time, not the Android start-time delta.
That performance failure is separate
from the functional matrix verdict. The analyzer also supports older runs with
only the four broad timing stages.

See [the measured whole-bootstrap diagnosis](WHOLE_BOOTSTRAP_PROFILE.md) for
results, measurement limits and the recommended optimization order.

The current [tier-specific budget decision](../../doc/bootstrap-performance-budget.md)
also records why interleaving three hashers is not equivalent to doing one hash,
and keeps framework host-interface reuse outside this milestone. Native channel
traces now separate codec, worker queue, lock wait and main-thread reply queue;
the analyzer reports those nested spans separately from the additive bootstrap
breakdown to avoid double-counting.

Native-bytes transport uses bootstrap profile schema 2. It removes Dart file
reopening and the payload/full-file SHA counters; entry SHA and CRC remain.
The analyzer requires the `native-bytes-v1` transport marker and still reads
schema-1 historical runs. A missing required counter is an error, not zero work.
See [the authenticated-byte design](../../doc/authenticated-bootstrap-bytes-design.md).

## Standalone cold/post-frame channel probe

This is a separate test APK, installed only after the formal matrix. It replaces
the dedicated acceptance app temporarily, uses the same SDK/ABI and copies the
frozen verifier and channel profiler into its own package. No production boot
transaction is repeated. It measures empty, whole-sized bytes, and verified
whole-sized bytes before binding creation and one second after the first frame.
Each mode has ten paired cold launches, with three-second spacing and dwell.
Its startup workload is not identical to the full acceptance host, so it is an
experiment about phase sensitivity, not proof of the actual engine queue cause.

Build on the authorized Linux host, with templates from `probe/`:
`python probe/build.py --run FROZEN_REMOTE_RUN --out FRESH_REMOTE_PROBE_DIR`.
Copy `probe.apk` and `build-result.json` back, then run locally:
`python test/acceptance/probe/run.py --apk PROBE_APK --serial SERIAL --out FRESH_RESULT_DIR`.
The runner emits `result.json`, preserves logs and checks request IDs, exact byte
digests outside timing, counter reconciliation and same-process liveness.
RSS/high-water RSS and post-frame dumpsys meminfo are observations for this fixed
payload, not a maximum-size transfer certification. Restore the freshly tested
acceptance APK afterward with `adb -s SERIAL install -r ACCEPTANCE_APK`.
