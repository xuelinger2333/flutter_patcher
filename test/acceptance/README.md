# Real-device fault matrix

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
budget alerts remain separate: a passing functional matrix does not prove whole
bootstrap meets 85 ms, cross-machine acceptance, or complete M1 release readiness.
Do not interact with the test app during the run. Installation may require the
phone's normal confirmation. No automatic retries or skipped cases are used.
