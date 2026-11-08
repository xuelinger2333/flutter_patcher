# Acceptance tests

## A patchable host on a real device

```powershell
python test/acceptance/device_acceptance.py --strategy so --signing signed --flutter-sdk PATH --serial SERIAL
```

Needs Python 3.12+, a JDK, the Android SDK and an unlocked API 28+ arm64
device; runs on Windows, Linux or macOS. Use `--strategy bytecode` for a
bytecode host and `--signing unsigned` for a host without a patch key. Each run
creates a fresh patch key (signed), a TLS certificate trusted only by the
fixture app, builds the host, makes three patches (a good one, one that throws
before its first frame, and a later good one), publishes them, a withdrawal
and the first patch again, serves the files from a local HTTPS origin reached
through `adb reverse`, then checks on the device:

- a tampered file (signature, or payload when unsigned) is rejected;
- a file the app fetches itself installs through `applyPatchBytes`;
- the patch boots twice, the same file is not applied again, rollback
  restores the original and the rolled-back file is not new;
- the crashing patch is quarantined by crash protection on the next start;
- a withdrawal removes the patch and an older file is not new after it;
- publishing the first patch again under a new sequence rolls back to it.

Output and `result.json` go to a fresh `.dart_tool/flutter_patcher/device/`
directory; the process exits nonzero on failure. Installation may need
on-device confirmation.

To build on the Linux builder instead, add `--remote gpu` (an SSH alias with
Flutter in `/opt/flutter` and the SDK in `/opt/android-sdk`; see
`--remote-*`). The current working tree, including uncommitted changes, is
snapshotted with a hash receipt (`source.json`), prepared remotely and the
APK, origin and TLS files are fetched back; the key and the baseline store stay
on the builder. `--prepare-only` stops before the device. After a device
problem, rerun only the device steps with `--resume-built --out THAT_DIR`.

## Other suites

- `native_tests.py` builds the plugin's JVM tests in a disposable host (CI).
- `linux_tests.py` runs the S3 store test against an isolated S3 emulator (CI).
- `test/ios/run.sh` runs the iOS rules and FPTC vectors on macOS.
- `ffi_boot/native_handles.cpp` checks the bootstrap FFI handles against an
  APK's library; see `android/BOOTSTRAP_FFI.md`.
