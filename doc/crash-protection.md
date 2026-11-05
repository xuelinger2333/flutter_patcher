# Crash Protection

**English** | [简体中文](crash-protection-zh.md)

When a patch makes the app fail to start, the device turns that patch off and runs its installed version from the next cold start. This works without setup; this page shows how to tune it, try it, and watch it in production.

## Set it up

**Goal**: choose how many failed starts turn a patch off.

**Do**: call `init` in `main()` before `runApp()`. These are the defaults; `init()` without arguments behaves the same:

```dart
await FlutterPatcher.init(
  maxCrashCount: 1,                     // failed starts before the patch is turned off
  verifyAfter: const Duration(seconds: 5), // after the first frame, Dart errors still count this long
);
```

A higher `maxCrashCount` tolerates an occasional failure, but a broken patch then costs users more failed starts. Keep the default unless you have a reason.

**Check**: after a cold start that runs a patch, `await FlutterPatcher.lastBootDiagnostic` has `status` `patched`.

## Try it on a device

**Goal**: see a bad patch turned off, before you rely on it.

**Before**: Steps 1–5 of [Getting Started](getting-started.md) are done, and `serve` is running.

**Do**:

1. Add `throw StateError('crash test');` as the first line of `main()`, run `dart run flutter_patcher patch android`, then remove the line again.
2. Open the app so it installs the patch: `serve` prints `A device downloaded the patch`.
3. Swipe the app away and open it: this start runs the patch and fails. The app may close or show a blank screen.
4. Open the app again.

**Check**:

- The app runs its installed version, and `lastBootDiagnostic` has `status` `droppedCircuitBreaker` and `message` `Bad state: crash test`.
- When the app checks for updates again, `serve` prints `A device checked for updates` but not `A device downloaded the patch`: the patch is blacklisted on this device.
- The next normal patch you make installs and runs as usual.

## What counts as a failed start

A start succeeds when the first frame is drawn and no uncaught Dart error follows within `verifyAfter`.

| Situation | Counts as |
|---|---|
| An uncaught Dart error before the first frame | Failure |
| An uncaught Dart error within `verifyAfter` after the first frame (foreground time only) | Failure |
| A crash, ANR or initialization failure before the first frame | Failure, settled at the next start |
| The user swipes the app away, or the system reclaims it, before the first frame | Not a failure on Android 11 and later; earlier versions cannot tell, so it counts |
| On iOS, the app goes to the background before the first frame | Not a failure |
| A crash or ANR after the first frame, while the patched process still runs | On Android 11 and later: a failure, settled at the next start. On Android 10 and earlier and on iOS: not detected; rely on your crash reporting |
| The patch's code cannot be loaded (a damaged file, or an authorization since withdrawn) | Failure |

On Android 11 and later the plugin reads how the patched process ended from the system's `ApplicationExitInfo`; only crashes, native crashes, ANRs and initialization failures count.

## After a failure

Each patch has its own failure count. Below `maxCrashCount`, the next start tries the patch again, and the diagnostic is `bytecodeBootFailed` (`soBootFailed` on SO hosts). When the count reaches `maxCrashCount`:

1. the patch is turned off, and the next cold start runs the app's installed version;
2. the patch goes on the device's blacklist, so `applyPatch` returns `blacklisted` if it meets the same patch again;
3. the boot diagnostic is `droppedCircuitBreaker`.

On an SO host whose `libapp.so` has already loaded, a patch whose rest then fails to load is blacklisted at once, whatever `maxCrashCount` is.

## What to do when it trips

The blacklist is per device: the patch is still in your publication store, and devices that have not tried it can still install it. When monitoring shows `droppedCircuitBreaker`:

1. [Withdraw the patch](production-playbook.md#rolling-back-and-withdrawing), either back to the installed version or to an earlier good patch.
2. Fix the problem and publish a new patch.

Do not publish the bad patch's output again: with a new sequence number it is a different patch to the blacklist, and devices install it again.

## Other ways a patch stops applying

| Situation | Result |
|---|---|
| The user upgrades the app | Patches for the old version stop applying; diagnostic `droppedVersionCodeMismatch` |
| You publish a withdrawal covering the patch's sequence | The device removes the patch once it applies the withdrawal; see [Production Deployment Guide](production-playbook.md#rolling-back-and-withdrawing) |
| The app calls `rollback()` | The patch is removed but not blacklisted. The device has accepted its sequence, so it cannot install that patch again; publish one with a higher sequence instead |
| The user clears app data or reinstalls | The patch and local records are gone |

## Boot diagnostics

`FlutterPatcher.lastBootDiagnostic` reports how the latest cold start handled the patch. Asked before this start's first frame, it waits for the first frame (at most 10 seconds) and reports this start.

**Report unhealthy starts** to your own monitoring:

```dart
final diag = await FlutterPatcher.lastBootDiagnostic;
if (diag != null && !diag.isHealthy) {
  report('patch_boot', {                 // your own reporting
    'status': diag.status.name,
    'patch': diag.patchVersion,
    'crashes': diag.crashCount,
    'message': diag.message,
  });
}
```

A start without a patch keeps an earlier `bytecodeBootFailed`, `soBootFailed`, `droppedCircuitBreaker` or `droppedVersionCodeMismatch` record, because it explains why no patch runs. The record stays until the next start with a patch; to report it once, compare `recordedAt` with the last one you reported.

| `status` | Meaning | `isHealthy` |
|---|---|:---:|
| `noPatch` | No patch installed | ✅ |
| `patched` | The patch loaded and the first frame was drawn | ✅ |
| `bytecodeBootFailed` | A start with a bytecode patch failed, below `maxCrashCount` | ❌ |
| `soBootFailed` | A start with an SO patch failed, below `maxCrashCount` | ❌ |
| `droppedCircuitBreaker` | The patch reached `maxCrashCount` and was turned off and blacklisted | ❌ |
| `droppedVersionCodeMismatch` | The app was upgraded; the old patch was dropped | ❌ |
| `hookInstallFailed` | On an Android SO host, patch loading could not be set up; this start ran the installed version | ❌ |
| `unknown` | Anything else; see `message` | ❌ |

Other fields: `patchVersion` (the patch sequence involved), `patchTargetVersionCode` (the app version the patch was installed on), `appVersionCode`, `crashCount` (the patch's failure count), `attemptedLoaderFields` (with `hookInstallFailed`), `recordedAt`, `message` (for developers).

## Blacklist

```dart
final entries = await FlutterPatcher.blacklist;   // inspect
await FlutterPatcher.clearBlacklist();            // clear, for tests or after ruling out the problem
```

Each `BlacklistEntry` has `version` (the patch's identity, `<fingerprint>:<sequence>:<sha256>`), `reason` (always `BOOT_CRASH`) and `blacklistedAt`.
