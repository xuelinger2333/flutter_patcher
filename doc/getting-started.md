# Getting Started

**English** | [简体中文](getting-started-zh.md)

**Goal**: add `flutter_patcher` to a Flutter app, change one line of UI text, and see the change on an Android phone after a cold start. Everything runs on your computer; no server is needed. The first run takes about 15 minutes, a few of them downloading the engine.

iOS differences are at the end; every command option is in the [CLI Reference](cli.md).

## Before you start

| You need | How to check |
|---|---|
| Linux x64, Windows x64 or an Apple Silicon Mac, with Git | `git --version` |
| Flutter 3.47.0 – 3.47.9 on your `PATH` | `flutter --version` |
| An `arm64-v8a` Android phone on Android 9 or later, with USB debugging on | `adb devices` lists it |
| A Flutter project whose `pubspec.yaml` `version` has a build number, such as `1.0.0+1` | Projects from `flutter create` do |
| Access to GitHub on the first run | The engine and tools come from there, then from the local cache |

## Step 1: Add the plugin

**Goal**: the app can check for and install patches.

**Do**:

1. In the project root, run:

   ```bash
   flutter pub add flutter_patcher
   dart run flutter_patcher doctor
   ```

2. Replace `main()` in `lib/main.dart` with the code below and add `checkForPatch()`. The app checks for an update every time it starts:

   ```dart
   import 'package:flutter/material.dart';
   import 'package:flutter_patcher/flutter_patcher.dart';

   Future<void> main() async {
     WidgetsFlutterBinding.ensureInitialized();
     await FlutterPatcher.init();
     runApp(const MyApp());
     checkForPatch();
   }

   Future<void> checkForPatch() async {
     try {
       final check = await FlutterPatcher.checkUpdate('http://127.0.0.1:8686');
       if (!check.hasUpdate) return;
       final result = await FlutterPatcher.applyPatch(check.patch!);
       debugPrint('applyPatch: $result');
     } on PatcherException catch (e) {
       debugPrint('checkUpdate failed: $e');
     }
   }
   ```

   `http://127.0.0.1:8686` is the local address `serve` provides in Step 5; in production, use your own HTTPS address, see the [Production Playbook](production-playbook.md).

3. Add the internet permission under `<manifest>` in `android/app/src/main/AndroidManifest.xml`. `flutter create` declares it only for debug and profile builds:

   ```xml
   <uses-permission android:name="android.permission.INTERNET"/>
   ```

**Check**:

- The last line of `doctor` starts with `Toolchain ready.` The first run downloads the engine and takes a few minutes.
- `flutter analyze` prints `No issues found!`.

If `doctor` fails, look up its error code in [Troubleshooting](troubleshooting.md).

## Step 2: Create the keys

**Goal**: the keys patches are signed with. Once per project.

**Do**:

```bash
dart run flutter_patcher keys init
```

**Check**: the output contains `"status":"keys_created"`, and `flutter_patcher.yaml` appears in the project root.

How the keys are stored and backed up: [Production Playbook: Back Up the Private Keys](production-playbook.md#step-1-back-up-the-private-keys).

## Step 3: Build and install the app

**Goal**: an app that accepts patches, installed on the phone.

**Do**:

```bash
dart run flutter_patcher build android
adb install <output>/app-release.apk
```

`<output>` is the directory in the `output` field of the JSON `build` prints.

**Check**:

- The last line `build` prints is JSON with `"status":"build_archived"`; `output` points to `.dart_tool/flutter_patcher/releases/<timestamp>/`, which holds `app-release.apk`.
- A `WARNING: BASELINE_STORE_LOCAL` line also appears. It means the baseline is kept only in the project, which is fine; before going live, see [Production Playbook: Keep These Two Directories](production-playbook.md#keep-these-two-directories).
- The app opens on the phone.

## Step 4: Change the code and make a patch

**Goal**: a patch with your change.

**Do**:

1. Change some text you can see on screen in `lib/main.dart`, such as the title. **Do not change `version` in `pubspec.yaml`**: the patch uses it to find the release from Step 3.
2. Run:

   ```bash
   dart run flutter_patcher patch android
   ```

**Check**: the output JSON contains `"status":"patch_created"`, and `changed` lists `package:<your package>/main.dart`; `.dart_tool/flutter_patcher/patches/<timestamp>/` holds `patch.draft` and `patch.json`.

When the change includes something a patch cannot carry, such as native code, the command fails with an error code such as `PATCH_NATIVE_CHANGE`; see [Troubleshooting](troubleshooting.md).

## Step 5: Send the patch to the phone

**Goal**: the phone downloads and installs the patch.

**Before**: the phone is connected to this computer over USB.

**Do**:

1. In another terminal, in the project root, run this and leave it running:

   ```bash
   dart run flutter_patcher serve
   ```

2. Open the app on the phone; if it is open, swipe it away from recent apps and open it again. It runs `checkForPatch()` as it starts.

**Check**:

- The `serve` terminal prints, in order:

  ```text
  Android device <serial> reaches this computer at 127.0.0.1:8686
  Offering patch 1 (versionCode 1 arm64-v8a)
  A device checked for updates
  A device downloaded the patch
  ```

- `adb logcat -s flutter` shows `applyPatch: PatchApplyResult(ok)`.

## Step 6: Cold start and see the change

**Goal**: run the patch.

**Do**: swipe the app away from recent apps and open it again.

**Check**: the screen shows the text you changed in Step 4.

For every later change: keep `serve` running, run `patch android`, and repeat Steps 5 and 6. `serve` prints `Offering patch 2 ...`, and the number keeps rising.

## Differences on iOS

| Stage | How it differs from Android |
|---|---|
| Build | `build ios` runs only on an Apple Silicon Mac, with signing (Team and Bundle ID) set up in Xcode. To install on your own phone, add `--export-method development`; the default, `app-store`, needs a distribution certificate. The output directory holds `app-release.ipa` |
| Signing | Run `build ios` in a terminal of the Mac's desktop session. Over SSH or in CI, unlock the keychain first, or signing fails with `errSecInternalComponent` |
| Install | For example, add the ipa in Xcode's Devices and Simulators window. With a free developer account, first trust the developer on the phone under Settings → General → VPN & Device Management |
| Make patches | `patch ios` runs on a Mac, Linux or Windows, on any computer that can read the baseline `build ios` saved |
| Deliver patches | An iPhone cannot reach the computer's `127.0.0.1`, and `checkUpdate` requires HTTPS. Expose `serve` over HTTPS with a tunnel, such as `cloudflared tunnel --url http://127.0.0.1:8686`, and pass that address to `checkUpdate` |

## Next steps

- What a patch can and cannot change: [How It Works](architecture.md#what-can-be-patched)
- Storage, publishing and withdrawing: [Production Playbook](production-playbook.md)
- What happens when a patch makes startup fail: [Crash Protection](crash-protection.md)
