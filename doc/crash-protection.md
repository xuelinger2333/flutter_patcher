# Crash Protection

**English** | [简体中文](crash-protection-zh.md)

> Choose how many failed starts turn a patch off, watch it happen on a phone, and read the boot diagnostics in production.

You have patches on devices and want to know what happens when one makes the app fail to start. The device turns the patch off, blacklists it, and runs the installed version from the next cold start. This page covers Android and iOS hosts. Errors after a start has succeeded are not detected here, so your crash reporting handles those.

## Set it up

**Goal**: choose how many failed starts turn a patch off.

**Do**: call `init` in `main()` before `runApp()`. The values below are the defaults, so `init()` without arguments behaves the same:

```dart
await FlutterPatcher.init(
  maxCrashCount: 1,                        // Failed starts before the patch is turned off.
  verifyAfter: const Duration(seconds: 5), // How long after the first frame Dart errors still count.
);
```

- A `maxCrashCount` above 1 tolerates a failure with another cause, such as a process crash unrelated to the patch, but a broken patch then fails that many starts before it is turned off. A Dart error thrown once the patch's code has started is not counted: the patch is turned off at once; see [After a failure](#after-a-failure). Values below 1 count as 1.
- Parameter details: [`init`](api-reference.md#init).

**Check**: after a cold start that runs a patch, `await FlutterPatcher.lastBootDiagnostic` has `status` `patched`.

## Try it on a device

**Goal**: watch a broken patch get turned off before you rely on it in production.

**Before**: the app from [Getting Started](getting-started.md) is installed, it checks for updates with `checkUpdate` and installs them with `applyPatch`, and `serve` is running.

**Do**:

1. Add `throw StateError('crash test');` as the first line of `main()`, run `dart run flutter_patcher patch android`, then remove the line again.
2. Open the app so it installs the patch: `serve` prints `A device downloaded 1-arm64-v8a.fptc` (your file name).
3. Swipe the app away and open it. This start runs the patch and fails: the app closes or shows a blank screen.
4. Open the app again.

**Check**:

- The app runs the installed version, and `lastBootDiagnostic` has `status` `droppedCircuitBreaker` and `message` `Bad state: crash test`.
- When the app checks again, `serve` prints `A device checked for updates` but not `A device downloaded`, because the device has accepted that file's sequence and blacklisted the patch.
- The next patch you make, without the `throw`, installs and runs.

## What counts as a failed start

A start succeeds when the first frame is drawn and no uncaught Dart error follows within `verifyAfter`.

| Situation | Counts as |
|---|---|
| An uncaught Dart error before the first frame | Failure |
| An uncaught Dart error within `verifyAfter` after the first frame; only time in the foreground counts | Failure |
| A crash, ANR or initialization failure before the first frame | Failure, recorded at the next start |
| The user swipes the app away, or the system reclaims it, before the first frame | Android 11 and later: not a failure, because the system records why the process ended. Android 10 and earlier: a failure, because it cannot be told from a crash |
| On iOS, the app goes to the background before the first frame | Not a failure: the attempt pauses until the app is in the foreground again |
| A crash or ANR after the first frame, while the patched process still runs | Android 11 and later: a failure, recorded at the next start. Android 10 and earlier, and iOS: not detected, so use your crash reporting |
| The installed patch fails its check at a cold start or cannot be loaded, for example a damaged file | Failure |

## After a failure

Each patch has its own count of consecutive failed starts, and a successful start resets it to 0.

- **Below `maxCrashCount`**: the next start tries the patch again. The diagnostic is `bytecodeBootFailed`, or `soBootFailed` on SO hosts.
- **At `maxCrashCount`**: the patch is turned off, so the next cold start runs the installed version. The patch is blacklisted on this device, so `applyPatch`, `applyPatchBytes` and `applyPatchFile` return `blacklisted` for the same file. The diagnostic is `droppedCircuitBreaker`.
- **Once the patch's code has started** (installing the patch's resources or running its `main()`), an uncaught Dart error turns the patch off and blacklists it at once, whatever `maxCrashCount` is, because the patch's code already ran and may have changed the app's state, so trying again is not safe. The diagnostic is `droppedCircuitBreaker`.
- **On an SO host**, a patch whose `libapp.so` loaded but whose remaining files then failed is blacklisted at once, whatever `maxCrashCount` is, because the loaded code already ran and must not run again.

## What to do when it trips

The blacklist is local to the device that recorded it, so the file is still wherever your app gets it, and devices that have not tried it still install it. When monitoring shows `droppedCircuitBreaker`:

1. **Withdraw the patch**, so devices return to the installed version, or publish an earlier good patch again; both are in [Delivering a rollback](production-playbook.md#delivering-a-rollback). With [Custom delivery](advanced.md#custom-delivery-from-your-own-server), hand the app the file the command writes.
2. **Fix the problem** and deliver a new patch.

> **Warning: do not publish the broken patch's output again**
>
> `publish --patch` seals it with a new sequence, which makes it a different file to the blacklist, so devices install and run it again.

## Other ways a patch stops applying

| Situation | Result |
|---|---|
| The user upgrades the app | Patches for the old version stop applying; the diagnostic is `droppedVersionCodeMismatch` |
| The device applies a withdrawal numbered above the patch | The patch is removed; the running process keeps its code, and the next cold start runs the installed version |
| The app calls `rollback()` | The patch is removed but not blacklisted; only a file with a higher sequence installs afterwards. See [`rollback`](api-reference.md#rollback) |
| The user clears app data or reinstalls the app | The patch and all local records are removed |

## Boot diagnostics

`FlutterPatcher.lastBootDiagnostic` reports how the latest cold start handled the patch.

- When this start runs a patch whose first frame is not drawn yet, the call waits for that frame, at most 10 seconds, so it reports this start rather than the previous one.
- It returns `null` when nothing has been recorded yet.

**Report unhealthy starts** to your own monitoring:

```dart
final diag = await FlutterPatcher.lastBootDiagnostic; // How the latest cold start handled the patch.
if (diag != null && !diag.isHealthy) {
  report('patch_boot', {                 // Sends the record to your monitoring.
    'status': diag.status.name,
    'patch': diag.patchVersion,
    'crashes': diag.crashCount,
    'message': diag.message,
  });
}
```

- A start without a patch keeps an earlier `bytecodeBootFailed`, `soBootFailed`, `droppedCircuitBreaker` or `droppedVersionCodeMismatch` record, because that record explains why no patch runs.
- A record stays until the next start with a patch, so to report it once, compare `recordedAt` with the last value you reported.

| `status` | Meaning | `isHealthy` |
|---|---|:---:|
| `noPatch` | No patch installed | ✅ |
| `patched` | The patch loaded and the first frame was drawn | ✅ |
| `bytecodeBootFailed` | A start with a bytecode patch failed, below `maxCrashCount` | ❌ |
| `soBootFailed` | A start with an SO patch failed, below `maxCrashCount` | ❌ |
| `droppedCircuitBreaker` | The patch reached `maxCrashCount` and was turned off and blacklisted | ❌ |
| `droppedVersionCodeMismatch` | The app was upgraded, so the old patch was dropped | ❌ |
| `hookInstallFailed` | Android SO hosts: patch loading could not be set up. This start ran the installed version; the patch stays installed | ❌ |
| `unknown` | Anything else; see `message` | ❌ |

Other fields of `PatchBootDiagnostic`:

| Field | Type | Description |
|---|---|---|
| `patchVersion` | `String?` | The `seq` of the patch involved; see [Patch files](cli.md#patch-files) |
| `patchTargetVersionCode` | `int?` | The app build number the patch was installed on |
| `appVersionCode` | `int?` | The app build number when the record was written |
| `crashCount` | `int?` | The patch's count of consecutive failed starts |
| `attemptedLoaderFields` | `List<String>?` | With `hookInstallFailed`: the loader fields that were tried |
| `recordedAt` | `DateTime` | When the record was written |
| `message` | `String?` | A description for developers; do not show it to users |

## Blacklist

```dart
final entries = await FlutterPatcher.blacklist; // Lists the patches blacklisted on this device.
await FlutterPatcher.clearBlacklist();          // Empties the blacklist and resets failure counts.
```

Each `BlacklistEntry` has:

| Field | Type | Description |
|---|---|---|
| `version` | `String` | The patch's identity: `<host fingerprint>:<seq>:<SHA-256 of the patch file>` |
| `reason` | `String` | Always `BOOT_CRASH` |
| `blacklistedAt` | `DateTime` | When the patch was blacklisted |

Clear the blacklist in tests, or after you have ruled out the cause of the failures.
