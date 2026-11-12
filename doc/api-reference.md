# API Reference

**English** | [简体中文](api-reference-zh.md)

Every static member of `FlutterPatcher`, and the types they take and return.

These APIs work only in an Android or iOS app built with `dart run flutter_patcher build`, called a host, because `build` writes into the app what the device needs to check patches; anything else is in [Platform support](#platform-support). How a host loads a patch is in [How It Works](architecture.md); the commands that write patch files are in the [CLI Reference](cli.md).

```dart
import 'package:flutter_patcher/flutter_patcher.dart';
```

## Overview

| Member | Description |
|---|---|
| [`init`](#init) | Configures crash protection; call it before `runApp()` |
| [`isAvailable`](#isavailable) | Whether this app can take patches |
| [`checkUpdate`](#checkupdate) | Checks a URL for a newer patch file for this host |
| [`applyPatch`](#applypatch) | Downloads and installs the file `checkUpdate` found |
| [`patchTarget`](#patchtarget) | Identifies this host, for the server in custom delivery |
| [`inspectPatch`](#inspectpatch) | Tells from a file's header whether installing it would change this host |
| [`applyPatchBytes`](#applypatchbytes) | Installs a patch file the app fetched itself, as bytes |
| [`applyPatchFile`](#applypatchfile) | Installs a patch file the app fetched itself, from a path on the device |
| [`applyProgress`](#applyprogress) | Progress of every install |
| [`currentVersion`](#currentversion) | The installed patch's `seq` |
| [`lastBootDiagnostic`](#lastbootdiagnostic) | How the latest cold start handled the patch |
| [`blacklist`](#blacklist) | Patches blacklisted on this device |
| [`appVersionCode`](#appversioncode) | The host's build number |
| [`deviceAbi`](#deviceabi) | The device's primary ABI |
| [`rollback`](#rollback) | Deletes the installed patch on this device |
| [`clearBlacklist`](#clearblacklist) | Empties this device's blacklist |

`patchTarget`, `inspectPatch`, `applyPatchBytes` and `applyPatchFile` need flutter_patcher 1.1.0 or newer, and `isAvailable` needs 1.1.1 or newer. Hosts built with flutter_patcher 1.0.0 are patched with flutter_patcher 1.0.0+1; see [Upgrading from 1.0](upgrading.md).

## Methods and properties

### `init`

```dart
static Future<void> init({
  int maxCrashCount = 1,
  List<String> loaderFieldCandidates = const ['flutterLoader'],
  bool loaderFallbackHeuristic = false,
  Duration verifyAfter = const Duration(seconds: 5),
})
```

Configures crash protection.

| Parameter | Description |
|---|---|
| `maxCrashCount` | How many consecutive failed starts of a patch turn it off and blacklist it. A Dart error thrown once the patch's code has started is not counted: the patch is turned off at once; see [After a failure](crash-protection.md#after-a-failure). Values below 1 count as 1 |
| `verifyAfter` | How long after the first frame an uncaught Dart error still counts as a failed start. Only time in the foreground counts |
| `loaderFieldCandidates`, `loaderFallbackHeuristic` | Android SO hosts only: how the plugin locates Flutter's loader. Keep the defaults unless you adapt a new Flutter version |

**Behavior**

- Call it in `main()` before `runApp()`, so its error hooks are in place before the first frame. Later calls have no effect.
- Native code marks a start successful at its first frame; `init` keeps reporting uncaught Dart errors for `verifyAfter` after it. What counts as a failed start and what happens next: [Crash Protection](crash-protection.md).

**Throws**: nothing.

### `isAvailable`

```dart
static Future<bool> get isAvailable
```

Whether this app can take patches: it runs on Android or iOS and was built with `dart run flutter_patcher build`. It is `false` in an app started with `flutter run` or built with `flutter build`.

**Throws**: never.

### `checkUpdate`

```dart
static Future<PatchCheckResult> checkUpdate({
  String? url,
  Duration timeout = const Duration(seconds: 10),
})
```

Checks `url` for a newer patch file for this host.

| Parameter | Description | Default |
|---|---|---|
| `url` | Where to look | The address `build` wrote into the app: `url` in `flutter_patcher.yaml`, or `http://127.0.0.1:8686`, where `serve` offers patches, when that is not set |
| `timeout` | Limit for the connection and the header read | 10 seconds |

**Returns**: a [`PatchCheckResult`](#patchcheckresult). When there is an update, pass its `patch` unchanged to [`applyPatch`](#applypatch).

**Behavior**

- Requests `GET <url>/<fileName>` with `Range: bytes=0-145`, where `<fileName>` is [`patchTarget.fileName`](#patchtarget), reads the first 146 bytes and judges them as [`inspectPatch`](#inspectpatch) does.
- `hasUpdate` is `true` only when the file is `fresh`: a newer patch or a newer withdrawal for this host.
- When [`isAvailable`](#isavailable) is `false`, no request is sent and there is no update.
- `404` means no update. Any status other than `200`, `206` or `404` throws, so the server must answer `404` for a missing file; the full requirements are in [CLI Reference: Download server](cli.md#download-server).
- The address must be HTTPS, because an unsigned host installs any intact file of its build and a file replaced in transit would run in the app. Plain HTTP is accepted only to the device itself, `http://127.0.0.1`, `http://[::1]` or `http://localhost`, where `serve` is reached through `adb reverse`.
- Redirects are not followed and the address must not contain a user name, a password or a `#` fragment, so a response cannot send the download elsewhere.

**Throws**: [`PatcherException`](#patcherexception) when no `url` is given and the app has none, and when the request fails, including a response shorter than 146 bytes.

### `applyPatch`

```dart
static Future<PatchApplyResult> applyPatch(
  PatchInfo patchInfo, {
  void Function(PatchApplyProgress)? onProgress,
})
```

Downloads the file `checkUpdate` found and installs it as [`applyPatchFile`](#applypatchfile) does.

| Parameter | Description |
|---|---|
| `patchInfo` | The [`PatchInfo`](#patchinfo) `checkUpdate` returned |
| `onProgress` | Receives this call's [`PatchApplyProgress`](#patchapplyprogress) |

**Returns**: a [`PatchApplyResult`](#patchapplyresult).

**Behavior**

- A patch takes effect on the next cold start, because the running process keeps its code; a withdrawal deletes the installed patch.
- The download must answer `200` with exactly the size the header announced, so an uncompressed response with a different `Content-Length` fails.
- It fails after 15 seconds without data or 2 minutes in total, whatever `checkUpdate`'s `timeout` was. Every download failure gives `network`.
- A `PatchInfo` without the `url` and `size` that `checkUpdate` sets gives `invalidArgs`.

**Throws**: nothing; every outcome is in the result.

```dart
final check = await FlutterPatcher.checkUpdate();
if (check.hasUpdate) {
  final result = await FlutterPatcher.applyPatch(check.patch!);
  if (!result.ok) debugPrint('${result.error?.name}: ${result.message}');
}
```

### `patchTarget`

```dart
static Future<PatchTarget> get patchTarget
```

Identifies this host. An app that fetches patch files itself sends these values to its server, which picks the file; see [Custom Delivery from Your Own Server](advanced.md#custom-delivery-from-your-own-server).

**Returns**: a [`PatchTarget`](#patchtarget-1).

**Throws**: [`PatcherException`](#patcherexception) on an app not built with flutter_patcher.

### `inspectPatch`

```dart
static Future<PatchInspection> inspectPatch(List<int> header)
```

Tells from the first 146 bytes of a file whether installing it would change this host, so the app can skip downloading a file the host would reject.

| Parameter | Description |
|---|---|
| `header` | The file's first 146 bytes; bytes beyond them are ignored |

**Returns**: a [`PatchInspection`](#patchinspection).

**Behavior**

- It checks only magic, version, fingerprint and `seq`, so installing still verifies the whole file.

**Throws**: [`PatcherException`](#patcherexception) on an app not built with flutter_patcher.

### `applyPatchBytes`

```dart
static Future<PatchApplyResult> applyPatchBytes(List<int> bytes)
```

Installs the patch file `bytes`, or applies the withdrawal it is.

| Parameter | Description |
|---|---|
| `bytes` | A whole file the CLI wrote for this host build: `file` in the `patch` output, or `<fileName>` in the publication store |

**Returns**: a [`PatchApplyResult`](#patchapplyresult).

**Behavior**

- Installs by the rules in [What a device accepts](#what-a-device-accepts), for the next cold start.

**Throws**: nothing; every outcome is in the result.

### `applyPatchFile`

```dart
static Future<PatchApplyResult> applyPatchFile(String path)
```

As [`applyPatchBytes`](#applypatchbytes), for a file on the device.

| Parameter | Description |
|---|---|
| `path` | The path of the patch file on the device |

**Returns**: a [`PatchApplyResult`](#patchapplyresult).

**Behavior**

- The file stays in place.
- A path that cannot be read gives `ioError`.

**Throws**: nothing; every outcome is in the result.

### `applyProgress`

```dart
static Stream<PatchApplyProgress> get applyProgress
```

A broadcast stream of the progress of every install.

**Returns**: a stream of [`PatchApplyProgress`](#patchapplyprogress).

**Behavior**

- It carries every phase of `applyPatch`, and `verifying` and `finalizing` of `applyPatchBytes` and `applyPatchFile`.
- Subscribe before installing, because a broadcast stream does not replay earlier events.

**Throws**: nothing.

### `currentVersion`

```dart
static Future<String?> get currentVersion
```

The installed patch's `seq` as a decimal string, or `null` without one.

**Behavior**

- It changes as soon as an install succeeds, while the patch runs from the next cold start, so until then it describes another patch than `lastBootDiagnostic`.

**Throws**: nothing; a failed read gives `null`.

### `lastBootDiagnostic`

```dart
static Future<PatchBootDiagnostic?> get lastBootDiagnostic
```

How the latest cold start handled the patch, or `null` without a record.

**Returns**: a [`PatchBootDiagnostic`](#patchbootdiagnostic).

**Behavior**

- A start that loaded a patch is recorded at its first frame; asked earlier, the getter completes then, with this start's record.

**Throws**: nothing; a failed read gives `null`.

```dart
final diag = await FlutterPatcher.lastBootDiagnostic; // The patch this start runs.
final installed = await FlutterPatcher.currentVersion; // The patch the next cold start runs.
debugPrint('running: ${diag?.status.name} ${diag?.patchVersion}; installed: $installed');
```

### `blacklist`

```dart
static Future<List<BlacklistEntry>> get blacklist
```

Patches blacklisted on this device.

**Returns**: a list of [`BlacklistEntry`](#blacklistentry); empty without any.

**Throws**: nothing; a failed read gives an empty list.

### `appVersionCode`

```dart
static Future<int?> get appVersionCode
```

The host's build number: Android versionCode, iOS CFBundleVersion.

**Throws**: nothing; `null` when unreadable.

### `deviceAbi`

```dart
static Future<String> get deviceAbi
```

The device's primary ABI: on Android the first of `Build.SUPPORTED_ABIS`, such as `arm64-v8a`; on iOS `ios-arm64`.

**Throws**: nothing; `''` when unreadable.

### `rollback`

```dart
static Future<void> rollback()
```

Deletes the installed patch on this device; the next cold start runs the installed version.

**Behavior**

- The patch is not blacklisted.
- `acceptedSeq` stays, so only a file with a higher `seq` can install afterwards.

**Throws**: nothing.

### `clearBlacklist`

```dart
static Future<void> clearBlacklist()
```

Empties this device's blacklist and resets every patch's failure count.

**Throws**: nothing.

## Types

### `PatchCheckResult`

Returned by [`checkUpdate`](#checkupdate).

| Field | Type | Description |
|---|---|---|
| `hasUpdate` | `bool` | Whether there is an update to apply: a newer patch or withdrawal |
| `patch` | `PatchInfo?` | The update; `null` without one |

### `PatchInfo`

The file `checkUpdate` found. Pass it unchanged to [`applyPatch`](#applypatch), because a `PatchInfo` built by hand lacks the fields the download needs and gives `invalidArgs`.

| Field | Type | Description |
|---|---|---|
| `version` | `String` | The file's `seq` as a string |
| `raw` | `Map<String, dynamic>` | `url`, `size`, `seq` and `action` (`publish` or `withdraw`) |

### `PatchApplyResult`

Returned by [`applyPatch`](#applypatch), [`applyPatchBytes`](#applypatchbytes) and [`applyPatchFile`](#applypatchfile).

| Field | Type | Description |
|---|---|---|
| `ok` | `bool` | Whether the file was installed or the withdrawal applied; installing the installed file again also succeeds |
| `error` | `PatchApplyError?` | Why it failed; `null` when `ok` |
| `message` | `String?` | A description for developers, not written for users |

### `PatchApplyError`

| Value | Meaning | What to do |
|---|---|---|
| `invalidArgs` | The file's `seq` is not above `acceptedSeq`: an older patch or withdrawal, or the same patch after `rollback()`. With `applyPatch`, also a `PatchInfo` that `checkUpdate` did not return | Deliver a file with a higher `seq`: run `patch` again, or `publish --patch <dir>` |
| `blacklisted` | This patch made a start fail and is blacklisted on this device | Deliver a fixed patch |
| `network` | `applyPatch` could not download the file | Retry later |
| `signatureInvalid` | Not this host's file (another build, flavor, channel or ABI), damaged or truncated, over 320 MiB, or not signed by the host's patch key | Do not retry, because the same file fails the same way; deliver the file named `patchTarget.fileName` of this build, signed by its key |
| `ioError` | The file could not be read, or a disk or file system error such as no space | Retry later |
| `unknown` | Anything else: an unsupported platform, an app not built with flutter_patcher, a patch the host rejects while installing | Report `message` |

```dart
switch (result.error) {
  case PatchApplyError.network || PatchApplyError.ioError:
    break; // Temporary; check again later.
  case PatchApplyError.blacklisted:
    break; // This patch failed a start here; wait for a fixed one.
  default:
    debugPrint('patch rejected: ${result.error?.name} ${result.message}');
}
```

### `PatchApplyProgress`

Emitted to `onProgress` of [`applyPatch`](#applypatch) and by [`applyProgress`](#applyprogress).

| Field | Type | Description |
|---|---|---|
| `phase` | `PatchApplyPhase` | The current phase |
| `bytesReceived`, `totalBytes` | `int` | Meaningful only while `downloading` |
| `fraction` | `double?` | Download progress from 0.0 to 1.0; `null` outside `downloading` or when the size is unknown |

### `PatchApplyPhase`

| Value | Meaning |
|---|---|
| `downloading` | Downloading the file; `applyPatch` only |
| `verifying` | Verifying the payload digest and signature |
| `finalizing` | Parsing the patch, installing its resources and committing |

### `PatchTarget`

Returned by [`patchTarget`](#patchtarget).

| Member | Type | Description |
|---|---|---|
| `fileName` | `String` | The name of this host's patch files: `<version_code>-<abi>.fptc` for the default flavor and channel, otherwise `<version_code>-<flavor>-<channel>-<abi>.fptc`. See [Patch files](cli.md#patch-files) |
| `versionCode`, `flavor`, `channel`, `abi` | `String` | The build, as `build` recorded it |
| `strategy` | `String` | `so` or `bytecode` |
| `fingerprint` | `String` | The host build's fingerprint; files of another fingerprint are rejected |
| `signed` | `bool` | Whether the host accepts only files signed by its patch key. Fixed when the host is built |
| `acceptedSeq` | `int` | The largest `seq` this host accepted, of a patch or a withdrawal; `0` before any. Only files numbered above it install |
| `scope` | `Map<String, String>` | `application_id`, `version_code`, `flavor`, `channel`, `abi`, `strategy` and `fingerprint` |

### `PatchInspection`

Returned by [`inspectPatch`](#inspectpatch).

| Field | Type | Description |
|---|---|---|
| `fresh` | `bool` | `true` when the header is this host's and its `seq` is above `acceptedSeq` |
| `action` | `String?` | `publish` for a patch, `withdraw` for a withdrawal; `null` when the bytes are not a patch file header |
| `seq` | `int?` | The file's sequence; `null` when the bytes are not a patch file header |
| `reason` | `String?` | Why the file is not `fresh`: `Patch file of another host`, `Not newer than the accepted patch`, or the parse error for bytes that are not a patch file header |

### `PatcherException`

Thrown by [`checkUpdate`](#checkupdate), [`patchTarget`](#patchtarget) and [`inspectPatch`](#inspectpatch).

| Field | Type | Description |
|---|---|---|
| `message` | `String` | The cause |

### `PatchBootDiagnostic`

Returned by [`lastBootDiagnostic`](#lastbootdiagnostic). Its fields and the meaning of each `status` are in [Crash Protection: Boot diagnostics](crash-protection.md#boot-diagnostics).

### `BlacklistEntry`

Returned by [`blacklist`](#blacklist). Its fields are in [Crash Protection: Blacklist](crash-protection.md#blacklist).

## What a device accepts

Every install goes through the same native check, whichever API hands over the file, so the delivery channel never decides what runs. The file format is in [CLI Reference: Patch files](cli.md#patch-files).

| File | Result |
|---|---|
| Over 320 MiB; wrong length, magic, version, host fingerprint or payload digest; or, on a signed host, a missing or invalid signature | Rejected: `signatureInvalid` |
| A blacklisted patch | Rejected: `blacklisted` |
| A patch with `seq` above `acceptedSeq` | Installed; `acceptedSeq` becomes its `seq`. It runs from the next cold start |
| The installed patch file again | Success; nothing changes |
| Any other patch with `seq` not above `acceptedSeq` | Rejected: `invalidArgs` |
| A withdrawal with `seq` above `acceptedSeq` | The installed patch is deleted and `acceptedSeq` becomes its `seq`. The running process keeps its code; the next cold start runs the installed version |
| A withdrawal with `seq` not above `acceptedSeq` | Rejected: `invalidArgs` |

`acceptedSeq` is kept per host build, so a new build of the app (a new fingerprint) starts at 0 and the previous build's patch no longer runs.

## Platform support

The plugin works only on Android and iOS. On any other platform every call does nothing and prints one warning on first use:

| API | On other platforms |
|---|---|
| `init`, `rollback`, `clearBlacklist` | Does nothing |
| `isAvailable` | `false` |
| `checkUpdate` | Reports no update |
| `applyPatch`, `applyPatchBytes`, `applyPatchFile` | Returns `unknown` |
| `patchTarget`, `inspectPatch` | Throws `PatcherException` |
| `applyProgress` | An empty stream |
| `currentVersion`, `lastBootDiagnostic`, `appVersionCode` | `null` |
| `deviceAbi` | `''` |
| `blacklist` | An empty list |

On Android and iOS, an app not built with `dart run flutter_patcher build` accepts no patches: `isAvailable` is `false`, `checkUpdate` reports no update, `patchTarget` and `inspectPatch` throw `PatcherException`, and `applyPatch`, `applyPatchBytes` and `applyPatchFile` return `unknown`.
