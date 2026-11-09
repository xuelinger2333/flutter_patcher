# API Reference

**English** | [简体中文](api-reference-zh.md)

This document lists the Dart API your app uses: the static members of `FlutterPatcher` and the types they take and return.

- The plugin works on Android and iOS only. On other platforms calls do nothing and print a warning the first time: getters return empty values, `checkUpdate` reports no update, `applyPatch`, `applyPatchBytes` and `applyPatchFile` return `unknown`, and `patchTarget` and `inspectPatch` throw `PatcherException`.
- Only hosts built with `flutter_patcher build` accept patches; see [How It Works](architecture.md).

```dart
import 'package:flutter_patcher/flutter_patcher.dart';
```

## Common tasks

### Check for an update and install it

**Goal**: download and install the host's patch file from `url` when there is a newer one, and handle every outcome.

```dart
import 'package:flutter/foundation.dart';
import 'package:flutter_patcher/flutter_patcher.dart';

Future<void> updateIfAvailable() async {
  final PatchCheckResult check;
  try {
    check = await FlutterPatcher.checkUpdate();
  } on PatcherException catch (e) {
    debugPrint('checkUpdate failed: $e'); // no network, an HTTP error, or no address
    return;
  }
  if (!check.hasUpdate) return;

  final result = await FlutterPatcher.applyPatch(
    check.patch!,
    onProgress: (p) => debugPrint('$p'),
  );
  if (result.ok) return; // runs from the next cold start

  switch (result.error) {
    case PatchApplyError.network || PatchApplyError.ioError:
      break; // temporary: check again later
    case PatchApplyError.blacklisted:
      break; // this patch failed to start on this device; wait for a fixed one
    default:
      debugPrint('patch rejected: ${result.error?.name} ${result.message}');
  }
}
```

**Check**: `result.ok` is `true`, and `await FlutterPatcher.currentVersion` returns the file's `seq`.

### Install a patch file you fetched yourself

See [Obtaining patch files yourself](#obtaining-patch-files-yourself).

### Show which patch is running

```dart
import 'package:flutter/foundation.dart';
import 'package:flutter_patcher/flutter_patcher.dart';

Future<void> showRunningPatch() async {
  final diag = await FlutterPatcher.lastBootDiagnostic; // how this start went
  final installed = await FlutterPatcher.currentVersion; // runs from the next cold start
  debugPrint('running: ${diag?.status.name} ${diag?.patchVersion}; installed: $installed');
}
```

`lastBootDiagnostic` describes the current start; `currentVersion` the installed patch. They differ between a successful install and the next cold start.

### Report unhealthy starts

See [Crash Protection](crash-protection.md).

## Initialization

### `init`

```dart
static Future<void> init({
  int maxCrashCount = 1,
  Duration verifyAfter = const Duration(seconds: 5),
})
```

Call it in `main()` before `runApp()`; calling it again has no effect. It configures crash protection and keeps counting uncaught Dart errors as a failed start for `verifyAfter` after the first frame. The start itself is confirmed natively at its first frame.

| Parameter | Description |
|---|---|
| `maxCrashCount` | How many consecutive failed starts roll a patch back and blacklist it |
| `verifyAfter` | How long after the first frame an uncaught Dart error still counts as a failed start (time in the foreground only) |

What these do in detail: [Crash Protection](crash-protection.md). `init` also takes `loaderFieldCandidates` and `loaderFallbackHeuristic`, which adapt to changes in Flutter's internals; keep their defaults.

## What a device accepts

Every install goes through the same native check, whichever API hands over the file. The file format is described in [CLI Reference: Patch files](cli.md#patch-files).

| File | Result |
|---|---|
| Wrong length, magic, version, host fingerprint or payload digest; or, on a signed host, a missing or invalid signature | Rejected: `signatureInvalid` |
| A patch with `seq` above `acceptedSeq` | Installed; `acceptedSeq` becomes its `seq`. It runs from the next cold start |
| The installed patch file again | Success; nothing changes |
| Any other patch with `seq` not above `acceptedSeq` | Rejected: `invalidArgs` |
| A blacklisted patch | Rejected: `blacklisted` |
| A withdrawal with `seq` above `acceptedSeq` | The installed patch is deleted and `acceptedSeq` becomes its `seq`. The running process continues; the next cold start runs the app's built-in version |
| A withdrawal with `seq` not above `acceptedSeq` | Rejected: `invalidArgs` |

- `acceptedSeq` is kept per host build. A new build of the app (a new fingerprint) starts at 0 and drops the previous build's patch.
- An unsigned host ignores the signature field and also accepts signed files.
- `rollback()` deletes the installed patch and keeps `acceptedSeq`, so the same file cannot be installed again; run `patch` again, or publish the output again (`publish --patch <dir>`), for a new `seq`.
- At each cold start the installed file is verified again before it loads.

## Patch files

### `patchTarget`

```dart
static Future<PatchTarget> get patchTarget
```

Who this host is. An app that fetches patch files itself sends these values to its server to pick the file. Throws `PatcherException` on an app not built with flutter_patcher.

**`PatchTarget`**

| Member | Description |
|---|---|
| `fileName` | The name the CLI gives this host's patch files: `<version_code>-<abi>.fptc` for the default flavor and channel (`default`, `production`), otherwise `<version_code>-<flavor>-<channel>-<abi>.fptc`, such as `1-arm64-v8a.fptc` or `3-paid-beta-arm64-v8a.fptc`. Flavors and channels contain only letters, digits and `_`, so no two hosts share a name |
| `versionCode`, `flavor`, `channel`, `abi`, `strategy` | The build, as `build` recorded it in the host policy |
| `fingerprint` | The host build's fingerprint; a file of another fingerprint is rejected |
| `signed` | Whether the host accepts only files signed by its patch key |
| `acceptedSeq` | The largest `seq` this host accepted, of a patch or a withdrawal; `0` before any. Only files numbered above it install |
| `scope` | All of the above as a map, plus `application_id` |

### `inspectPatch`

```dart
static Future<PatchInspection> inspectPatch(List<int> header)
```

Tells from the first 146 bytes of a file (more are ignored) whether installing it would change this host, before you download the rest. It checks magic, version, fingerprint and `seq` only; installing still verifies the whole file. On an app not built with flutter_patcher it throws a `PlatformException`.

**`PatchInspection`**

| Field | Description |
|---|---|
| `fresh` | `true` when the header is this host's and its `seq` is above `acceptedSeq` |
| `action` | `publish` for a patch, `withdraw` for a withdrawal; `null` when the bytes are not a patch file header |
| `seq` | The file's sequence; `null` when the bytes are not a patch file header |
| `reason` | Why it is not `fresh`, for example `Patch file of another host` or `Not newer than the accepted patch` |

### `applyPatchBytes`

```dart
static Future<PatchApplyResult> applyPatchBytes(List<int> bytes)
```

Installs the patch file `bytes`, or applies the withdrawal it is, by the rules in [What a device accepts](#what-a-device-accepts). The bytes are written to a temporary file for native verification, which is deleted afterwards. It does not throw; every outcome is in the result.

### `applyPatchFile`

```dart
static Future<PatchApplyResult> applyPatchFile(String path)
```

As `applyPatchBytes`, for a file on the device. The file is left in place. A path that cannot be read gives `ioError`.

## Built-in downloader

`checkUpdate` and `applyPatch` download the host's file from a URL where the CLI's files are placed. You do not need them when the app obtains files itself.

### `checkUpdate`

```dart
static Future<PatchCheckResult> checkUpdate({
  String? url,
  Duration timeout = const Duration(seconds: 10),
})
```

Requests `GET <url>/<fileName>` with `Range: bytes=0-145`, reads the first 146 bytes and judges them with `inspectPatch`.

- Without `url`, it uses the address `build` wrote into the app: `url` in `flutter_patcher.yaml`, or `http://127.0.0.1:8686`, where `serve` offers patches, when that is not set. Pass `url` to check elsewhere, such as an HTTPS tunnel to `serve` for an iPhone.
- `hasUpdate` is `true` only when the file is `fresh`: a newer patch or a newer withdrawal of this host.
- `404` means no update. Any status other than `200`, `206` or `404` throws, so a store that answers `403` for a missing file, as private S3 and R2 buckets often do, must be set to answer `404`.
- The address must be HTTPS, except the device's own `http://127.0.0.1`, `http://[::1]` or `http://localhost` used by `serve`. It must not contain a user name, a password or a `#` fragment, and redirects are not followed.
- `timeout` limits the connection and the header read.
- Throws `PatcherException` when the app was not built with flutter_patcher, when no `url` is given and the app has none, and when the request fails, including a response shorter than 146 bytes.

**`PatchCheckResult`**

| Field | Description |
|---|---|
| `hasUpdate` | Whether there is an update to apply |
| `patch` | The update; pass it unchanged to `applyPatch`. `patch.version` is its `seq` as a string; `patch.raw` holds `url`, `size`, `seq` and `action` (`publish` or `withdraw`) |

### `applyPatch`

```dart
static Future<PatchApplyResult> applyPatch(
  PatchInfo patchInfo, {
  void Function(PatchApplyProgress)? onProgress,
})
```

Downloads the file `checkUpdate` found to a temporary file and installs it as `applyPatchFile` does; the temporary file is deleted afterwards. **A patch takes effect on the next cold start**; the running process keeps its current code. A withdrawal deletes the installed patch.

- The download expects `200` and exactly the size the header announced (a `Content-Length` other than that size fails, unless the response is compressed). It fails after 15 seconds without data or 2 minutes in total, independent of `checkUpdate`'s `timeout`. Every download failure is `network`; call `checkUpdate` again later.
- A `PatchInfo` that `checkUpdate` did not return gives `invalidArgs`.
- It does not throw; every outcome is in the result.

## Results

**`PatchApplyResult`**, returned by `applyPatch`, `applyPatchBytes` and `applyPatchFile`:

| Field | Description |
|---|---|
| `ok` | Whether the file was installed or the withdrawal applied; the installed file again also succeeds |
| `error` | Why it failed, a `PatchApplyError` |
| `message` | A description for developers; do not show it to users |

**`PatchApplyError`**

| Value | Meaning | What to do |
|---|---|---|
| `invalidArgs` | The file's `seq` is not above `acceptedSeq`: an older patch or withdrawal, or the same patch after `rollback`. With `applyPatch`, also a `PatchInfo` that `checkUpdate` did not return | Run `patch` again, or publish the patch output again (`publish --patch <dir>`), for a new `seq` |
| `blacklisted` | This patch made a start fail and is blacklisted on this device | Publish a fixed patch |
| `network` | `applyPatch` could not download the file | Retry later |
| `signatureInvalid` | Not this host's file (another build, flavor, channel or ABI), damaged or truncated, or not signed by the host's patch key | Do not retry; deliver the file named `patchTarget.fileName` of this build, signed by its key |
| `ioError` | The file could not be read, or a disk or file system error such as no space | Retry later |
| `unknown` | Anything else: an unsupported platform, an app not built with flutter_patcher, a patch the host rejects while installing | Report `message` |

### Progress

`onProgress` and the `applyProgress` stream receive `PatchApplyProgress`:

| Field | Description |
|---|---|
| `phase` | `downloading` (`applyPatch` only), `verifying`, `finalizing` |
| `bytesReceived` / `totalBytes` | Meaningful only while `downloading` |
| `fraction` | Download progress from 0.0 to 1.0, or `null` when unknown |

`applyProgress` is a broadcast stream; subscribe before installing. It also reports `verifying` and `finalizing` for `applyPatchBytes` and `applyPatchFile`.

## Status

| API | Description |
|---|---|
| `currentVersion` | The installed patch's `seq` as a decimal string (Unix seconds when it was sealed), or `null`. It changes as soon as an install succeeds, but the patch runs only after the next cold start |
| `lastBootDiagnostic` | How the latest cold start handled the patch; see [Crash Protection](crash-protection.md) |
| `blacklist` | Patches blacklisted on this device; `BlacklistEntry.version` is `<fingerprint>:<seq>:<SHA-256>` |
| `appVersionCode` | The host's version: Android versionCode, iOS CFBundleVersion |
| `deviceAbi` | The device's primary ABI: on Android the first of `Build.SUPPORTED_ABIS` (such as `arm64-v8a`), on iOS `ios-arm64` |

## Manual actions

| API | Description |
|---|---|
| `rollback()` | Deletes the installed patch; the next cold start runs the app's built-in version. Does not blacklist the patch and keeps `acceptedSeq`, so that file cannot be installed again |
| `clearBlacklist()` | Empties this device's blacklist, for tests or after you have ruled out the problem |

## Obtaining patch files yourself

The plugin does not need to fetch anything: any way the app obtains the file works, such as your own API, a CDN, a push message, a file bundled with an update or picked by the user. The file must be the one the CLI wrote for this host build, `<fileName>` in the `patch` output or in the publication store.

```dart
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_patcher/flutter_patcher.dart';

/// Asks your server for this host's patch file and installs it.
Future<void> updateFromMyServer() async {
  final target = await FlutterPatcher.patchTarget;
  final uri = Uri.https('api.example.com', '/patches', {
    'file': target.fileName,
    'fingerprint': target.fingerprint,
    'after': '${target.acceptedSeq}',
  });
  final client = HttpClient();
  try {
    final response = await (await client.getUrl(uri)).close();
    if (response.statusCode == HttpStatus.noContent) return; // nothing newer
    if (response.statusCode != HttpStatus.ok) {
      throw HttpException('HTTP ${response.statusCode}', uri: uri);
    }
    final bytes = await consolidateHttpClientResponseBytes(response);
    final result = await FlutterPatcher.applyPatchBytes(bytes);
    if (!result.ok) {
      debugPrint('patch rejected: ${result.error?.name} ${result.message}');
    }
  } finally {
    client.close();
  }
}
```

- The server picks the file by `fileName` (and `fingerprint` when one name may have several builds); which users get which file is the server's choice.
- Only a file with `seq` above `acceptedSeq` installs; the server may skip sending others, or the app can check the first 146 bytes with `inspectPatch`.
- On an unsigned host, whoever can hand the app a file can run code in it: protect the transport yourself. A signed host rejects any file its patch key did not sign, wherever it came from.

## Removed in 1.1

`SignedManifest`, `SignedUpdateResult`, `fetchSignedManifest`, `applySignedManifest` and `updatePublicationTrust` no longer exist; code using them does not compile. Use `applyPatchBytes` or `applyPatchFile` for files you obtain, or `checkUpdate` and `applyPatch` to download from a URL.
