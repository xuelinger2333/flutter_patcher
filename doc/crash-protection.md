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

**Before**: the app from [Getting Started](getting-started.md) checks for updates with `checkUpdate` and applies them with `applyPatch`, and `serve` is running.

**Do**:

1. Add `throw StateError('crash test');` as the first line of `main()`, run `dart run flutter_patcher patch android`, then remove the line again.
2. Open the app so it installs the patch: `serve` prints `A device downloaded <file name>`, for example `A device downloaded 1-arm64-v8a.fptc`.
3. Swipe the app away and open it: this start runs the patch and fails. The app may close or show a blank screen.
4. Open the app again.

**Check**:

- The app runs its installed version, and `lastBootDiagnostic` has `status` `droppedCircuitBreaker` and `message` `Bad state: crash test`.
- When the app checks for updates again, `serve` prints `A device checked for updates` but not `A device downloaded`: the device has accepted that file's sequence and blacklisted the patch.
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
| The installed patch no longer passes its checks or cannot be loaded (for example, a damaged file) | Failure |

On Android 11 and later the plugin reads how the patched process ended from the system's `ApplicationExitInfo`; only crashes, native crashes, ANRs and initialization failures count.

## After a failure

Each patch has its own failure count. Below `maxCrashCount`, the next start tries the patch again, and the diagnostic is `bytecodeBootFailed` (`soBootFailed` on SO hosts). When the count reaches `maxCrashCount`:

1. the patch is turned off, and the next cold start runs the app's installed version;
2. the patch goes on the device's blacklist, so `applyPatchBytes`, `applyPatchFile` and `applyPatch` return `blacklisted` if they meet the same file again;
3. the boot diagnostic is `droppedCircuitBreaker`.

On an SO host whose `libapp.so` has already loaded, a patch whose rest then fails to load is blacklisted at once, whatever `maxCrashCount` is.

## What to do when it trips

The blacklist is per device: the file is still wherever your app gets it, and devices that have not tried it can still install it. When monitoring shows `droppedCircuitBreaker`:

1. Stop the bad patch: deliver a withdrawal, made with `patch android --withdraw` (or `ios`) or written to the store with `publish --withdraw`, so devices go back to the installed version; or publish an earlier good patch output again with `publish --patch <its output directory>`, which seals it with a new sequence. If your app gets files another way, hand it the file this writes. See [Production Deployment Guide](production-playbook.md).
2. Fix the problem and publish a new patch.

Do not publish the bad patch's output again: with a new sequence it is a different file to the blacklist, and devices install it again.

## Other ways a patch stops applying

| Situation | Result |
|---|---|
| The user upgrades the app | Patches for the old version stop applying; diagnostic `droppedVersionCodeMismatch` |
| The device applies a withdrawal numbered above the patch (`patch --withdraw` or `publish --withdraw`) | The patch is removed; the running process keeps its code, and the next cold start runs the installed version |
| The app calls `rollback()` | The patch is removed but not blacklisted. The device keeps the highest sequence it accepted, so it cannot install that file again; publish a newer one instead |
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

Other fields: `patchVersion` (the sequence of the patch involved: the Unix time in seconds it was sealed, unless `publish --seq` set it), `patchTargetVersionCode` (the app version the patch was installed on), `appVersionCode`, `crashCount` (the patch's failure count), `attemptedLoaderFields` (with `hookInstallFailed`), `recordedAt`, `message` (for developers).

## Blacklist

```dart
final entries = await FlutterPatcher.blacklist;   // inspect
await FlutterPatcher.clearBlacklist();            // clear, for tests or after ruling out the problem
```

Each `BlacklistEntry` has `version` (the patch's identity, `<host fingerprint>:<sequence>:<SHA-256 of the patch file>`), `reason` (always `BOOT_CRASH`) and `blacklistedAt`.
