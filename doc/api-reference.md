# API Reference

**English** | [简体中文](api-reference-zh.md)

This document lists the Dart API your app uses, all static members of `FlutterPatcher`.

- The plugin works on Android and iOS only. On other platforms calls do nothing and print a warning the first time: getters return empty values, `checkUpdate` reports no update and `applyPatch` returns `unknown`. `fetchSignedManifest`, `applySignedManifest` and `updatePublicationTrust` are not guarded and fail there.
- Only hosts built with `flutter_patcher build` accept patches; see [How It Works](architecture.md#the-host-an-app-that-accepts-patches).

```dart
import 'package:flutter_patcher/flutter_patcher.dart';
```

## Initialization

### `init`

```dart
static Future<void> init({
  int maxCrashCount = 1,
  Duration verifyAfter = const Duration(seconds: 5),
})
```

Call it in `main()` before `runApp()`; calling it again has no effect. It turns on crash protection: it marks the start successful after the first frame and keeps watching for Dart errors for `verifyAfter`.

| Parameter | Description |
|---|---|
| `maxCrashCount` | How many consecutive failed starts roll a patch back and blacklist it |
| `verifyAfter` | How long after the first frame an uncaught Dart error still counts as a failed start (time in the foreground only) |

What these do in detail: [Crash Protection](crash-protection.md). `init` also takes `loaderFieldCandidates` and `loaderFallbackHeuristic`, which adapt to changes in Flutter's internals; keep their defaults.

## Checking for and installing updates

### `checkUpdate`

```dart
static Future<PatchCheckResult> checkUpdate(
  String url, {
  Duration timeout = const Duration(seconds: 10),
})
```

`url` is the root address where your publication store is served, such as `https://cdn.example.com/my-app`, or `http://127.0.0.1:8686` from `serve` while developing. The plugin reads this host's manifest there and verifies it in native code.

- `hasUpdate` is `true` only when accepting the manifest would change the device: a patch with a higher sequence number, or a new withdrawal. A patch already installed is not an update.
- Once `applyPatch` has downloaded a patch, the device has accepted its manifest, even if installing then fails; `checkUpdate` no longer reports it. To retry, call `applyPatch` again with the same `PatchInfo`.
- When nothing has been published, the store answers 404 and `checkUpdate` returns `hasUpdate: false`. Any other error status throws, so a store that answers 403 for a missing file, as private S3 and R2 buckets often do, must be set to answer 404.
- The address must be HTTPS, except the device's own `http://127.0.0.1`, `http://[::1]` or `http://localhost` used by `serve`. It must not contain a user name, a password or a `#` fragment, and redirects are not followed. A manifest larger than 24,000 bytes is rejected.
- Network errors, a manifest that fails verification, or a host not built with `flutter_patcher build` throw a `PatcherException`.

**`PatchCheckResult`**

| Field | Description |
|---|---|
| `hasUpdate` | Whether there is an update to install |
| `patch` | The update; pass it unchanged to `applyPatch`. `patch.version` is the patch sequence number, or `withdraw` for a withdrawal |

### `applyPatch`

```dart
static Future<PatchApplyResult> applyPatch(
  PatchInfo patchInfo, {
  void Function(PatchApplyProgress)? onProgress,
})
```

Downloads and installs the update `checkUpdate` returned. Native code verifies the manifest again, then the patch's hash, signature, host and sequence number, and commits it atomically only when all pass. **The patch takes effect on the next cold start**; the running process keeps its current code. For a withdrawal, the installed patch is removed instead.

The download has its own limits, independent of `checkUpdate`'s `timeout`: it fails after 15 seconds without data or 2 minutes in total.

It does not throw; every outcome is in the result.

**`PatchApplyResult`**

| Field | Description |
|---|---|
| `ok` | Whether it installed; installing the same patch again also succeeds |
| `error` | Why it failed, a `PatchApplyError` |
| `message` | A description for developers; do not show it to users |

**`PatchApplyError`**

| Value | Meaning | What to do |
|---|---|---|
| `network` | The patch download failed | Retry later |
| `ioError` | A disk or file system error, such as no space | Retry later with the same `PatchInfo` |
| `signatureInvalid` | The patch signature did not verify; on iOS also when the app did not start through flutter_patcher's generated entry point | Do not retry; check your publishing, storage and build |
| `blacklisted` | This patch made a start fail and is blacklisted on this device | Publish a fixed patch |
| `invalidArgs` | Not a result from `checkUpdate`, or the patch's sequence is not above the one the device accepted | Check how you call it and how you publish |
| `unknown` | Anything else, including a manifest that fails verification, a patch whose size or hash differs from its manifest, and a plugin older than the manifest requires | Report `message` |


### Progress

`onProgress` and the `applyProgress` stream receive `PatchApplyProgress`:

| Field | Description |
|---|---|
| `phase` | `downloading`, `verifying`, `finalizing` |
| `bytesReceived` / `totalBytes` | Meaningful only while `downloading` |
| `fraction` | Download progress from 0.0 to 1.0, or `null` when unknown |

`applyProgress` is a broadcast stream; subscribe before calling `applyPatch`.

## Status

| API | Description |
|---|---|
| `currentVersion` | Sequence number of the installed patch, or `null`. It changes as soon as `applyPatch` succeeds, but the patch runs only after the next cold start |
| `lastBootDiagnostic` | How the latest cold start handled the patch; see [Crash Protection](crash-protection.md#boot-diagnostics) |
| `blacklist` | Patches blacklisted on this device |
| `appVersionCode` | The host's version: Android versionCode, iOS CFBundleVersion |
| `deviceAbi` | The device's primary ABI: on Android the first of `Build.SUPPORTED_ABIS` (such as `arm64-v8a`), on iOS `ios-arm64` |

## Manual actions

| API | Description |
|---|---|
| `rollback()` | Removes the installed patch; the next cold start runs the app's built-in version. Does not blacklist the patch, but the device has accepted its sequence, so it cannot install that patch again; publish one with a higher sequence |
| `clearBlacklist()` | Empties this device's blacklist, for tests or after you have ruled out the problem |
| `reportBootSuccess()` | Marks this start successful by hand. `init` calls it after the first frame, so you rarely need it |

## Delivering manifests yourself

If your app should not read the publication store directly (for example, requests must pass through your own authenticated API), fetch the manifest and patch yourself and hand them to the plugin to verify and install:

```dart
// 1. The manifest: the file named by the manifest field of publish's result
//    (manifests/<hash>.json), kept exactly as published.
final manifest = await FlutterPatcher.fetchSignedManifest(manifestUrl);
// or: SignedManifest.parse(theExactStringFromYourApi)

// 2. Hand it over with the store's root address, or with the patch bytes.
final result = await FlutterPatcher.applySignedManifest(
  manifest,
  baseUrl: storeUrl,      // one of the two
  // payload: patchBytes,
);
// result.action is 'publish' or 'withdraw'; result.result is a PatchApplyResult
```

The signature covers the manifest's exact text: any rewrite, even reformatting the JSON, fails verification.

Unlike `applyPatch`, these throw: `fetchSignedManifest` a `FormatException` when nothing is published at that address, and `applySignedManifest` an `ArgumentError` without `baseUrl` or `payload`, or a `PlatformException` when native code rejects the manifest.

`updatePublicationTrust(SignedManifest)` applies a root-signed trust update on the device, together with the `trust` command; see [Advanced Operations](advanced.md#rotating-the-publisher-key).
