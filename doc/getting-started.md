# Getting Started

**English** | [简体中文](getting-started-zh.md)

**Goal**: add `flutter_patcher` to a Flutter app, change one line of UI text, and see the change on an Android phone after a cold start. Everything runs on your computer; no server, no keys and no `flutter_patcher.yaml` are needed. The first run takes about 15 minutes, a few of them downloading the engine.

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
       final check = await FlutterPatcher.checkUpdate();
       if (!check.hasUpdate) return;
       final result = await FlutterPatcher.applyPatch(check.patch!);
       debugPrint('applyPatch: $result');
     } on PatcherException catch (e) {
       debugPrint('checkUpdate failed: $e');
     }
   }
   ```

   `checkUpdate()` requests `<url>/<file name>` and reads only its first 146 bytes, the file header, to see whether the file is new to this app. `<url>` is the address `build` wrote into the app: `url` in `flutter_patcher.yaml`, or, while there is none, `http://127.0.0.1:8686`, where `serve` offers patches in Step 4. Passing it explicitly works the same: `checkUpdate(url: 'http://127.0.0.1:8686')`.

**Check**:

- The last line of `doctor` starts with `Toolchain ready.` The first run downloads the engine and takes a few minutes.
- `flutter analyze` prints `No issues found!`.

If `doctor` fails, look up its error code in [Troubleshooting](troubleshooting.md).

`checkUpdate` is only a built-in downloader. An app can get the patch file any other way and install it itself; see [Fetching the file yourself](#fetching-the-file-yourself).

## Step 2: Build and install the app

**Goal**: an app that accepts patches, installed on the phone.

**Do**:

```bash
dart run flutter_patcher build android
adb install <output>/app-release.apk
```

`<output>` is the directory in the `output` field of the JSON `build` prints.

**Check**:

- The last line `build` prints is a short JSON summary with `"status":"build_archived"`; `app` is the APK to install, in `.dart_tool/flutter_patcher/releases/<timestamp>/`, and `report` the full build report beside it.
- Three warnings also appear, all expected while trying things out:
  - `WARNING: UNSIGNED`: the app accepts patch files that are not signed. Signing is optional; see [Production Deployment Guide: Enable signing](production-playbook.md#3-optional-enable-signing).
  - `WARNING: URL_LOCAL`: the app checks `serve`'s local address.
  - `WARNING: BASELINE_STORE_LOCAL`: the baseline, which every patch of this build needs, is kept only in the project's `.flutter_patcher/baselines/`.
- The app opens on the phone.

## Step 3: Change the code and make a patch

**Goal**: a patch file with your change.

**Do**:

1. Change some text you can see on screen in `lib/main.dart`, such as the title. **Do not change `version` in `pubspec.yaml`**: the patch uses it to find the build from Step 2.
2. Run:

   ```bash
   dart run flutter_patcher patch android
   ```

**Check**: the output JSON contains `"status":"patch_created"`, `changed` lists `package:<your package>/main.dart`, and `file` is the patch file, such as `.dart_tool/flutter_patcher/patches/<timestamp>/1-arm64-v8a.fptc`. Its name is `<version_code>-<abi>.fptc`, and also names the flavor and channel when they are not the defaults (see [Patch files](cli.md#patch-files)); `seq` is its sequence, the Unix time in seconds when it was made.

When the change includes something a patch cannot carry, such as native code, the command fails with an error code such as `PATCH_NATIVE_CHANGE`; see [Troubleshooting](troubleshooting.md).

## Step 4: Send the patch to the phone

**Goal**: the phone downloads and installs the patch.

**Before**: the phone is connected to this computer over USB.

**Do**:

1. In another terminal, in the project root, run this and leave it running:

   ```bash
   dart run flutter_patcher serve
   ```

   `serve` serves the newest file `patch` wrote, exactly as written, at `http://127.0.0.1:8686`, and maps that port onto the phone with `adb reverse`. It is a debugging aid only: it publishes, numbers and signs nothing.

2. Open the app on the phone; if it is open, swipe it away from recent apps and open it again. It runs `checkForPatch()` as it starts.

**Check**:

- After its startup notes, the `serve` terminal prints:

  ```text
  Android device <serial> reaches this computer at 127.0.0.1:8686
  Offering patch <seq> (1-arm64-v8a.fptc, unsigned)
  A device checked for updates
  A device downloaded 1-arm64-v8a.fptc
  ```

- `adb logcat -s flutter` shows `applyPatch: PatchApplyResult(ok)`.

## Step 5: Cold start and see the change

**Goal**: run the patch.

**Do**: swipe the app away from recent apps and open it again.

**Check**: the screen shows the text you changed in Step 3.

For every later change: keep `serve` running, run `patch android`, and repeat Steps 4 and 5. `serve` picks up the new file within about 2 seconds and prints `Offering patch <seq> ...` with a higher sequence each time; a device installs only a file numbered above every file it accepted before.

## Going back to the installed version

```bash
dart run flutter_patcher patch android --withdraw
```

This writes a withdrawal of the build from Step 2 under the same file name; it needs only the baseline, nothing is compiled. `serve` prints `Offering a withdrawal of <file> ...`. Open the app so it applies it, then cold start it: it runs the installed version again. `FlutterPatcher.rollback()` does the same on one phone only.

## Self-hosted delivery

`build` and `patch` are all you need to ship patches yourself; `serve` is only for development. Put the file `patch` wrote anywhere, such as your own server, a CDN or any other channel, and either:

- let the built-in downloader fetch it: `checkUpdate(url: …)`, or `checkUpdate()` with `url` set in `flutter_patcher.yaml` before `build`. The file must be at `<url>/<file name>`, where the file name is `(await FlutterPatcher.patchTarget).fileName`. The address must be HTTPS, except the device itself (`127.0.0.1`, `[::1]`, `localhost`); `404` means no update; redirects are not followed; range support is not required;
- or fetch it yourself and pass it to `applyPatchBytes` / `applyPatchFile`, as below.

When `patch` prints `"file":null`, the host is signed and this machine lacks its patch key: run `keys import` and patch again.

### Fetching the file yourself

The plugin does not have to download anything. An app that gets patch files from its own API, a push message, a file picker or its assets passes the bytes to `applyPatchBytes` (or a path to `applyPatchFile`). `patchTarget` says which file this build needs. A sketch with the `http` package:

```dart
import 'package:flutter/foundation.dart';
import 'package:flutter_patcher/flutter_patcher.dart';
import 'package:http/http.dart' as http;

Future<void> fetchPatch() async {
  final target = await FlutterPatcher.patchTarget;
  // Your server picks the file from target.fileName (or versionCode, flavor,
  // channel, abi) and target.acceptedSeq, the last sequence this app took.
  final response = await http.get(
    Uri.parse(
      'https://api.example.com/patches/${target.fileName}'
      '?after=${target.acceptedSeq}',
    ),
  );
  if (response.statusCode != 200) return;
  final result = await FlutterPatcher.applyPatchBytes(response.bodyBytes);
  debugPrint('applyPatchBytes: $result');
}
```

The file is the `.fptc` that `patch` or `publish` wrote. The device verifies it the same way whatever delivered it. Every API is in the [API Reference](api-reference.md).

## Differences on iOS

| Stage | How it differs from Android |
|---|---|
| Build | `build ios` runs only on an Apple Silicon Mac, with signing (Team and Bundle ID) set up in Xcode. To install on your own phone, add `--export-method development`; the default, `app-store`, needs a distribution certificate. The output directory holds `app-release.ipa` |
| Code signing | Run `build ios` in a terminal of the Mac's desktop session. Over SSH or in CI, unlock the keychain first, or signing fails with `errSecInternalComponent` |
| Install | For example, add the ipa in Xcode's Devices and Simulators window. With a free developer account, first trust the developer on the phone under Settings → General → VPN & Device Management |
| Make patches | `patch ios` runs on a Mac, Linux or Windows, on any computer that can read the baseline `build ios` saved. The file is named like `1-ios-arm64.fptc` |
| Deliver patches | An iPhone cannot reach the computer's `127.0.0.1`, and `checkUpdate` accepts plain HTTP only for `127.0.0.1`/`localhost`. Either expose `serve` over HTTPS with a tunnel, such as `cloudflared tunnel --url http://127.0.0.1:8686`, and pass that address: `checkUpdate(url: 'https://…')`; or get the `.fptc` onto the phone another way and [install it yourself](#fetching-the-file-yourself) |

## Next steps

- What a patch can and cannot change: [How It Works](architecture.md)
- Hosting patch files, signing, withdrawing and rolling back: [Production Deployment Guide](production-playbook.md)
- What happens when a patch makes startup fail: [Crash Protection](crash-protection.md)
