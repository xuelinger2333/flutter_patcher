# Acceptance tests

## Authenticated host on a real device

```powershell
python test/acceptance/authenticated_device.py --strategy so --flutter-sdk PATH --serial SERIAL
```

Needs Python 3.12+, a JDK, the Android SDK and an unlocked API 28+ arm64
device; runs on Windows, Linux or macOS. Use `--strategy bytecode` for a
bytecode host. Each run creates fresh keys and a TLS certificate trusted only
by the fixture app, builds the host, makes three patches (a good one, one that
exits before its first frame, and a later good one), publishes them plus a
withdrawal to a local HTTPS origin reached through `adb reverse`, then checks
on the device:

- a tampered signature and a corrupted payload are rejected, and a retry of
  the same manifest after the corrupted download succeeds;
- the patch boots twice, the same manifest is not re-applied, rollback
  restores the original, and the old manifest cannot be replayed;
- the crashing patch is quarantined by crash protection on the next start;
- a withdrawal removes an installed patch.

Output and `result.json` go to a fresh
`.dart_tool/flutter_patcher/authenticated/` directory; the process exits
nonzero on failure. Installation may need on-device confirmation.

To build on the Linux builder instead, add `--remote gpu` (an SSH alias with
Flutter in `/opt/flutter` and the SDK in `/opt/android-sdk`; see
`--remote-*`). The current working tree, including uncommitted changes, is
snapshotted with a hash receipt (`source.json`), prepared remotely and the
APK, origin and TLS files are fetched back; keys and the baseline store stay on
the builder. After a device problem, rerun only the device steps with
`--resume-built --out THAT_DIR`.

## Other suites

- `native_tests.py` builds the plugin's JVM tests in a disposable host (CI).
- `linux_tests.py` runs the CLI tests against an isolated S3 emulator (CI).
- `run_authenticated_native.py` runs the authenticated state/race
  instrumentation tests and a two-process recovery on a device.
- `ffi_boot/native_handles.cpp` checks the bootstrap FFI handles against an
  APK's library; see `android/BOOTSTRAP_FFI.md`.