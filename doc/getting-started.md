# Getting Started

**English** | [简体中文](getting-started-zh.md)

This guide walks you through a complete hotfix cycle from scratch: integrating `flutter_patcher` into an Android app, modifying a line of UI text, and seeing the change take effect after a cold start. Everything runs locally without setting up a remote server (iOS differences are covered at the end).

For full command flags, see the [CLI Reference](cli.md); for under-the-hood mechanics, see [Architecture](architecture.md).

## Prerequisites

- **Build Host**: Linux x64, Windows x64 or Apple Silicon Mac
- **Flutter**: 3.47.0 – 3.47.9 (available in `PATH`)
- **Git**: Installed and available in `PATH`
- **Test Device**: An `arm64-v8a` Android device (Android 9+) with USB debugging enabled and visible via `adb devices`
- **Network**: Internet access is required on the first run to download the matching custom Flutter engine and toolchain from GitHub (cached locally for subsequent runs)

## 1. Integrate the SDK

Add the dependency:

```bash
flutter pub add flutter_patcher
```

Then verify your environment from the project root:

```bash
dart run flutter_patcher doctor
```

If the last line starts with `Toolchain ready.`, you are good to go. If it fails, look up the reported error code in [Troubleshooting](troubleshooting.md).

Initialize `FlutterPatcher` in `main()`, and trigger an update check at an appropriate point in your app (e.g., on a button tap or screen load):

```dart
import 'package:flutter/material.dart';
import 'package:flutter_patcher/flutter_patcher.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await FlutterPatcher.init();
  runApp(const MyApp());
}

Future<void> checkForPatch() async {
  final check = await FlutterPatcher.checkUpdate('http://127.0.0.1:8686');
  if (!check.hasUpdate) return;
  final result = await FlutterPatcher.applyPatch(check.patch!);
  debugPrint('applyPatch: $result'); // When 'ok', takes effect on next cold start
}
```

- `http://127.0.0.1:8686` points to the local dev server started by `serve` in Step 5. For production, replace this with your own HTTPS endpoint (see [Production Playbook](production-playbook.md)).
- Release builds need the internet permission to check for updates. `flutter create` declares it only for debug and profile builds, so add `<uses-permission android:name="android.permission.INTERNET"/>` to `android/app/src/main/AndroidManifest.xml`.
- Make sure `version` in `pubspec.yaml` includes a build number (e.g., `version: 1.0.0+1`). The build number maps to Android's `versionCode`, which `flutter_patcher` uses to match patches against the exact baseline release.

## 2. Generate Signing Keys

```bash
dart run flutter_patcher keys init
```

This creates two items in your project root:

| Path | Description |
|---|---|
| `flutter_patcher_keys/` | Three cryptographic keypairs. Private keys are automatically ignored by a bundled `.gitignore`—**back them up to a secure location immediately**. |
| `flutter_patcher.yaml` | Configuration template (all options commented out by default). No changes needed for local testing. |

## 3. Build the Baseline Release

```bash
dart run flutter_patcher build android
```

`build` compiles a release APK using the `flutter_patcher` engine and saves a baseline snapshot of this release. The first run will take longer while it downloads engine artifacts and prepares the toolchain.

When finished, the CLI outputs a single-line JSON object. The `output` field points to the release directory (defaults to `.dart_tool/flutter_patcher/releases/`), which contains the store-ready `app-release.apk`. Install it on your device:

```bash
adb install <output>/app-release.apk
```

Launch the app and verify it runs normally.

> **Note**: The `WARNING: BASELINE_STORE_LOCAL` message indicates that the baseline snapshot is currently stored only in your local project directory. You can ignore this for local testing; before going to production, configure persistent baseline storage as described in the [Production Playbook](production-playbook.md).

## 4. Modify Code & Generate a Patch

Change any text string in your UI—**do not change the `version` in `pubspec.yaml`**—and run:

```bash
dart run flutter_patcher patch android
```

`patch` locates the baseline saved in Step 3, diffs your changes, and generates a patch bundle. On success, the JSON output shows `"status": "patch_created"` and lists modified items under `changed`.

If your changes include unsupported modifications (such as native code edits), the command fails immediately with an error code and reason. See [Troubleshooting](troubleshooting.md) for details.

## 5. Serve the Patch to Your Device

With your phone connected via USB, start the local patch server:

```bash
dart run flutter_patcher serve
```

`serve` automatically performs three actions:
1. Publishes the latest patch to local storage (`.flutter_patcher/updates/`);
2. Starts an HTTP server listening on `127.0.0.1:8686`;
3. Runs `adb reverse` on connected Android devices so `127.0.0.1:8686` on the phone routes directly to your computer.

Leave `serve` running and trigger `checkForPatch()` in your app. The `serve` terminal will log `A device checked for updates` followed by `A device downloaded the patch`, and the app logs `applyPatch: PatchApplyResult(ok)`.

## 6. Cold Start to Verify

Force-close the app completely (swipe it away from the recent apps screen) and relaunch it. You will see the updated UI text.

If you edit the code again and re-run `patch android` while `serve` is running, `serve` automatically publishes the new patch with an auto-incremented sequence number. Simply trigger an update check in the app and cold-start again.

## Differences on iOS

- **Building the baseline**: Run `build ios` on an Apple Silicon Mac. Code signing uses your existing Xcode project settings, producing `app-release.ipa` in the output directory.
- **Cross-platform patching**: `patch ios` can run on macOS, Linux, or Windows, provided the machine has access to the baseline snapshot saved by `build ios` (see baseline storage in the [Production Playbook](production-playbook.md)).
- **Local device testing**: iOS devices cannot route `127.0.0.1` to your host machine via `adb reverse`. As prompted when starting `serve`, expose the local port via an HTTPS tunnel (e.g., `cloudflared tunnel --url http://127.0.0.1:8686`) and pass the tunnel URL to `checkUpdate`.

## Next Steps

- Understand how patches work and what cannot be patched: [Architecture](architecture.md)
- Prepare for production (storage, CDN, staged rollouts): [Production Playbook](production-playbook.md)
- Learn what happens if a bad patch crashes on startup: [Crash Protection](crash-protection.md)