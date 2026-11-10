# flutter_patcher

[![pub package](https://img.shields.io/pub/v/flutter_patcher.svg)](https://pub.dev/packages/flutter_patcher)
[![ci](https://github.com/xuelinger2333/flutter_patcher/actions/workflows/ci.yml/badge.svg)](https://github.com/xuelinger2333/flutter_patcher/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

**English** | [简体中文](README-zh.md)

**Open-source, self-hosted over-the-air (OTA) hotfix tool for Flutter (Android & iOS).** Ship critical bug fixes directly from your own servers or CDN without waiting for app store reviews.

flutter_patcher is a Flutter plugin with a command-line tool:

1. `build` builds the app you release.
2. After a fix, `patch` makes one patch file.
3. You put the file on your HTTPS server. The app downloads it and runs it from the next cold start.

Changes to native code or to the Flutter version still need a store release.

## Requirements

| Flutter | Android | iOS |
|---|:---:|:---:|
| 3.47.0 – 3.47.9 | ✅ | ✅ |

| For | You need |
|---|---|
| Android devices | Android 9 (API 28) or later, `arm64-v8a`. On Android 7 and 8 the app runs as built, without patches |
| iOS devices | iOS 13 or later |
| `build android` | Linux x64, Windows x64 or an Apple Silicon Mac |
| `build ios` | An Apple Silicon Mac with Xcode |
| `patch android`, `patch ios` | Any of the computers above |

## What can be patched

| Change | Patchable | Why |
|---|:---:|---|
| Your Dart code | ✅ | |
| Pure-Dart dependencies, such as `dio` or `intl` | ✅ | |
| Added or changed images, fonts and other assets | ✅ | |
| Removed assets | ❌ | A patch overrides assets and cannot remove them |
| Native code, platform plugins and FFI packages, such as `mmkv` or `isar` | ❌ | A patch carries only Dart code and assets |
| The Flutter SDK version | ❌ | A patch is built with the Flutter version that built its release |

`patch` checks these limits and fails with an error code when a change breaks one. The full list is in [How It Works](doc/architecture.md#what-can-be-patched).

## Quick start

1. Add the dependency, initialize, and check for a patch:

   ```bash
   flutter pub add flutter_patcher
   dart run flutter_patcher init   # Creates flutter_patcher.yaml and the patch key, signing off
   ```

   ```dart
   Future<void> main() async {
     WidgetsFlutterBinding.ensureInitialized();
     await FlutterPatcher.init(); // Initializes flutter_patcher; call it before runApp.
     runApp(const MyApp());
   }

   // Checks for a new patch, by default at 127.0.0.1:8686 where serve offers it.
   final check = await FlutterPatcher.checkUpdate();
   if (check.hasUpdate) {
     // Downloads and verifies the patch; it takes effect on the next cold start.
     await FlutterPatcher.applyPatch(check.patch!);
   }
   ```

2. Build the app and install it. `build` also records the baseline that every later patch of this build is compared with:

   ```bash
   dart run flutter_patcher build android   # Or build ios, on an Apple Silicon Mac
   ```

3. Change the Dart code, then make the patch. `patch` prints the path of the patch file as `file`:

   ```bash
   dart run flutter_patcher patch android   # Writes one file, such as 1-arm64-v8a.fptc
   ```

4. Offer the patch to a phone connected over USB, then open the app twice: the first start installs the patch, the second runs it.

   ```bash
   dart run flutter_patcher serve   # Offers the newest patch at 127.0.0.1:8686; development only
   ```

Each step with its expected output is in [Getting Started](doc/getting-started.md).

## Before you ship

To keep development and debugging simple, flutter_patcher makes three main features optional. Turning on all three before you release is strongly recommended:

- **Update address**: pass the HTTPS address that serves your patch files as `checkUpdate(url: …)`, because without it the app asks `serve` on your computer. An app with [custom delivery](doc/advanced.md#custom-delivery-from-your-own-server) does not need it.
- **Baseline store**: set `baseline_store` in `flutter_patcher.yaml` to durable storage, because a build whose baseline is lost can no longer be patched (`WARNING: BASELINE_STORE_LOCAL`).
- **Signing**: set `trust.enabled: true` in `flutter_patcher.yaml`, because an unsigned app installs any intact patch file of its build, so whoever can hand it a file can run code in it (`WARNING: UNSIGNED`).

The steps are in the [Production Deployment Guide](doc/production-playbook.md).

> **Note**
> Some app stores and regulated industries restrict downloading executable code. Check the rules of the stores you ship in.

## Documentation

| Document | What it covers |
|---|---|
| [Getting Started](doc/getting-started.md) | From adding the dependency to a patch running on a phone |
| [How It Works](doc/architecture.md) | Hosts, baselines, the two patch strategies, the security model, what can be patched |
| [CLI Reference](doc/cli.md) | Every command, option, output and exit code; `flutter_patcher.yaml` |
| [API Reference](doc/api-reference.md) | The Dart API the app calls |
| [Production Deployment Guide](doc/production-playbook.md) | Hosting patch files, keeping baselines, signing, rolling back, upgrading from 1.0 |
| [Advanced Operations](doc/advanced.md) | KMS signing, keys in CI, stopping signing, custom host policy, S3, delivery from your own server |
| [Upgrading from 1.0](doc/upgrading.md) | Keep patching apps shipped with 1.0.0 |
| [Crash Protection](doc/crash-protection.md) | What happens when a patch fails at startup; boot diagnostics |
| [Troubleshooting](doc/troubleshooting.md) | Every error code and warning, with fixes |
| [FAQ](doc/faq.md) | Short answers with links |

## Contributing

Issues and pull requests are welcome. Before submitting, run:

```bash
flutter pub get
flutter analyze
flutter test
```

A change to native code also needs the on-device acceptance tests in [`test/acceptance`](test/acceptance/README.md), because unit tests do not load a patch on a device.

## License

[MIT](LICENSE)
