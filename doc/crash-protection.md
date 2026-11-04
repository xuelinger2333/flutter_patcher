# Crash Protection

**English** | [简体中文](crash-protection-zh.md)

A patch can pass every build-time check and still crash at startup on some devices. This document explains how the plugin notices, how it recovers on its own, and how you can watch it.

It works without setup; call [`FlutterPatcher.init()`](api-reference.md#init) in `main()` to set `maxCrashCount` and keep counting Dart errors after the first frame.

## A start with a patch

```text
cold start with an installed patch
  → record "trying to start this patch"
  → load the patch and run the app
  → first frame drawn → the start succeeded; the failure count resets
```

If the process ends before the first frame, or Dart code throws an uncaught error, the start counts as **failed**.

## What counts as a failed start

| Situation | Counts as |
|---|---|
| An uncaught Dart error before the first frame | Failure |
| An uncaught Dart error within `verifyAfter` after the first frame (default 5 seconds, foreground time only) | Failure |
| A crash, ANR or initialization failure before the first frame | Failure, settled at the next start |
| The user swipes the app away, or the system reclaims it, before the first frame | Not a failure on Android 11 and later; earlier versions cannot tell, so it counts |
| On iOS, the app goes to the background before the first frame | Not a failure |
| A crash or ANR after the first frame, while the patched process still runs | On Android 11 and later: a failure, settled at the next start. On Android 10 and earlier and on iOS: not detected; rely on your crash reporting |

On Android 11 and later the plugin reads how the patched process ended from the system's `ApplicationExitInfo`; only crashes, native crashes, ANRs and initialization failures count, whenever they happen in that process.

## After a failure

Each patch has its own failure count. When it reaches `maxCrashCount` (default 1), the **circuit breaker** trips:

1. the patch is turned off, and the next cold start runs the app's built-in version;
2. the patch goes on the device's **blacklist**, so `applyPatch` returns `blacklisted` if it meets the same patch again;
3. the boot diagnostic records `droppedCircuitBreaker`.

Below the threshold, the next start tries the patch again and the diagnostic is `bytecodeBootFailed` (`soBootFailed` on SO hosts).

A patch whose code cannot be loaded (for example a damaged file, or an authorization that was withdrawn) also counts as one failure. On an SO host whose `libapp.so` has already loaded, a patch whose rest then fails to load is blacklisted at once, whatever `maxCrashCount` is.

A higher `maxCrashCount` tolerates occasional failures, but a broken patch then costs users more failed starts. The default suits most apps.

## Other ways a patch stops applying

| Situation | Result |
|---|---|
| The user upgrades the app | Patches for the old version stop applying; diagnostic `droppedVersionCodeMismatch` |
| You publish a withdrawal covering the patch's sequence | The device removes the patch once it checks for updates and applies the withdrawal; see [Production Playbook](production-playbook.md#withdrawing-a-patch) |
| The app calls `rollback()` | The patch is removed but not blacklisted. The device has accepted its sequence, so it cannot install that patch again; publish one with a higher sequence instead |
| The user clears app data or reinstalls | The patch and local records are gone |

## Boot diagnostics

`FlutterPatcher.lastBootDiagnostic` reports how the latest cold start handled the patch. Asked before this start's first frame, it waits for the first frame (at most 10 seconds) and reports this start.

A start without a patch keeps an earlier `bytecodeBootFailed`, `soBootFailed`, `droppedCircuitBreaker` or `droppedVersionCodeMismatch` record, because it explains why no patch runs. That record therefore stays until the next start with a patch; to report it once, compare `recordedAt` with the last one you reported.

```dart
final diag = await FlutterPatcher.lastBootDiagnostic;
if (diag != null && !diag.isHealthy) {
  // Use your own reporting
  report('patch_boot', {
    'status': diag.status.name,
    'patch': diag.patchVersion,
    'crashes': diag.crashCount,
    'message': diag.message,
  });
}
```

**`status` values**

| Value | Meaning | `isHealthy` |
|---|---|:---:|
| `noPatch` | No patch installed | ✅ |
| `patched` | The patch loaded and the first frame was drawn | ✅ |
| `bytecodeBootFailed` | A start with a bytecode patch failed, below the circuit-breaker threshold | ❌ |
| `soBootFailed` | A start with an SO patch failed, below the circuit-breaker threshold | ❌ |
| `droppedCircuitBreaker` | The patch reached the failure threshold and was turned off and blacklisted | ❌ |
| `droppedVersionCodeMismatch` | The app was upgraded; the old patch was dropped | ❌ |
| `hookInstallFailed` | On an Android SO host, patch loading could not be set up; this start ran the built-in version | ❌ |
| `unknown` | Anything else; see `message` | ❌ |


**Other fields**: `patchVersion` (the patch sequence involved), `patchTargetVersionCode` (the app version the patch was installed on), `appVersionCode`, `crashCount` (the patch's failure count), `attemptedLoaderFields` (with `hookInstallFailed`), `recordedAt`, `message` (for developers).

## Blacklist

```dart
final entries = await FlutterPatcher.blacklist;   // inspect
await FlutterPatcher.clearBlacklist();            // clear
```

Each `BlacklistEntry` has `version` (the patch's identity, `<fingerprint>:<sequence>:<sha256>`), `reason` (always `BOOT_CRASH`) and `blacklistedAt`.

The blacklist is per device: the patch is still in your publication store and other devices can still download it. When monitoring shows `droppedCircuitBreaker`, [withdraw](production-playbook.md#withdrawing-a-patch) the patch or publish a fix promptly.
