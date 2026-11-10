# Getting Started

**English** | [简体中文](getting-started-zh.md)

> Change one line of text in a Flutter app and see the change reach an Android phone as a patch, without reinstalling the app.

Everything here runs on your computer and a phone connected over USB, so you need no server and no signing key. It takes about 15 minutes, including a few minutes for the first download of the engine. For an iPhone, see [Differences on iOS](#differences-on-ios).

## Before you start

| You need | How to check |
|---|---|
| Linux x64, Windows x64 or an Apple Silicon Mac, with Git | `git --version` |
| Flutter 3.47.0 to 3.47.9 on your `PATH` | `flutter --version` |
| An `arm64-v8a` Android phone on Android 9 or later, with USB debugging on | `adb devices` lists it |
| A Flutter project whose `pubspec.yaml` `version` has a build number, such as `1.0.0+1` | Projects from `flutter create` do |
| Access to GitHub on the first run | The engine and tools download from there once |

## Step 1: Add the dependency

```bash
flutter pub add flutter_patcher
dart run flutter_patcher init
dart run flutter_patcher doctor
```

The last line of `doctor` should start with `Toolchain ready.` If it fails, look up its error code in [Troubleshooting](troubleshooting.md).

Then change `lib/main.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_patcher/flutter_patcher.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await FlutterPatcher.init(); // Call it before runApp.
  runApp(const MyApp());
  checkForPatch();
}

Future<void> checkForPatch() async {
  try {
    final check = await FlutterPatcher.checkUpdate(); // Default address 127.0.0.1:8686.
    if (!check.hasUpdate) return;
    final result = await FlutterPatcher.applyPatch(check.patch!); // Takes effect on the next cold start.
    debugPrint('applyPatch: $result');
  } on PatcherException catch (e) {
    debugPrint('checkUpdate failed: $e');
  }
}
```

## Step 2: Build and install

```bash
dart run flutter_patcher build android
adb install <app>   # The "app" path in the output of build
```

The output has two warnings, `UNSIGNED` and `BASELINE_STORE_LOCAL`. Ignore them while you try things out locally; before you ship, see the [Production Deployment Guide](production-playbook.md).

## Step 3: Change the code and make a patch

Change some text you can see on screen in `lib/main.dart`, then run:

```bash
dart run flutter_patcher patch android
```

The output `"status":"patch_created"` means it worked.

> Do not change `version` in `pubspec.yaml`, or `patch` fails with `BASELINE_NOT_FOUND`.

## Step 4: Run the patch on the phone

Keep the phone connected over USB. In a second terminal, run this and leave it running:

```bash
dart run flutter_patcher serve
```

Close the app from recent apps and open it, twice: the first time it downloads the patch, the second time it runs it. The screen shows your change from Step 3 when it worked.

For each later change, keep `serve` running, run `patch android` again, and close and open the app twice.

Not working? See [Troubleshooting](troubleshooting.md#checkupdate-never-finds-an-update). To withdraw a patch, see [Delivering a rollback](production-playbook.md#delivering-a-rollback).

## Differences on iOS

| Stage | How it differs from Android |
|---|---|
| Build | `build ios` runs only on an Apple Silicon Mac with signing (Team and Bundle ID) set up in Xcode. To install on your own phone, add `--export-method development`, because the default `app-store` needs a distribution certificate. The output is `app-release.ipa` |
| Code signing | Run `build ios` in a terminal of the Mac's desktop session. Over SSH or in CI, unlock the keychain first, or signing fails with `errSecInternalComponent` |
| Install | For example, add the ipa in Xcode's Devices and Simulators window. With a free developer account, first trust the developer on the phone under Settings → General → VPN & Device Management |
| Make patches | `patch ios` runs on a Mac, Linux or Windows computer that can read the baseline `build ios` saved. The file is named like `1-ios-arm64.fptc` |
| Deliver patches | An iPhone cannot reach the computer's `127.0.0.1`, and `checkUpdate` allows plain HTTP only to the device itself. Expose `serve` over HTTPS with a tunnel, such as `cloudflared tunnel --url http://127.0.0.1:8686`, and pass that address: `checkUpdate(url: 'https://…')` |

## Next steps

- What a patch can and cannot change, and why it takes effect after a cold start: [How It Works](architecture.md)
- Shipping an app that takes patches: [Production Deployment Guide](production-playbook.md)
- What happens when a patch makes startup fail: [Crash Protection](crash-protection.md)
