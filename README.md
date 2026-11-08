# flutter_patcher

[![pub package](https://img.shields.io/pub/v/flutter_patcher.svg)](https://pub.dev/packages/flutter_patcher)
[![ci](https://github.com/xuelinger2333/flutter_patcher/actions/workflows/ci.yml/badge.svg)](https://github.com/xuelinger2333/flutter_patcher/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

**English** | [简体中文](README-zh.md)

**Open-source, self-hosted over-the-air (OTA) hotfix tool for Flutter (Android & iOS).** Ship critical bug fixes directly from your own servers or CDN without waiting for app store reviews.

## Features

- **Open-Source & Self-Hosted**: Fully transparent codebase with zero third-party platform dependencies. A patch is one file; deliver it from any server, CDN or API you control.
- **Fetch It Your Way**: The app obtains the patch file however it likes (your own API, a CDN, a push, a file) and hands it to the plugin. A built-in downloader is included for the simple case.
- **Cross-Platform Patching**: Supports both Android and iOS. Patches for either platform can be generated from any supported host OS (e.g., build iOS patches directly on a Linux CI runner).
- **Code & Asset Updates**: Patch application Dart code, pure-Dart dependencies, images, fonts, and other bundled assets.
- **Build-Time Safety Checks**: Unsupported changes (such as native code or FFI modifications) are caught and blocked with clear error messages during patch generation—before they ever reach production.
- **Automatic Rollback**: Automatically reverts to the bundled baseline build if a patch fails on startup.
- **Verification & Optional Signing**: Every patch file is checked on-device for its target build and integrity before it is installed. Turn on signing and the app accepts only patches signed with your private key.

## Supported Versions & Requirements

| Flutter | Android | iOS |
|---|:---:|:---:|
| 3.47.0 – 3.47.9 | ✅ | ✅ |

| Target / Stage | Requirements |
|---|---|
| Android Device | Android 9 (API 28) or higher, `arm64-v8a`; on Android 7–8 the app runs as built, without patches |
| iOS Device | iOS 13 or higher |
| Build Android Release | Linux x64, Windows x64 or Apple Silicon Mac |
| Build iOS Release | Apple Silicon Mac (Xcode required) |
| Generate Patches | Any host above can generate both Android and iOS patches |

## What Can Be Patched

| Change Type | Supported | Notes |
|---|:---:|---|
| App Dart code | ✅ | UI and business logic |
| Pure-Dart dependencies | ✅ | Packages without native code (e.g., `dio`, `intl`) |
| Images, fonts & assets | ✅ | Adding or modifying assets; deleting assets requires a full app release |
| Native code, plugins & FFI | ❌ | Kotlin/Swift/C++, platform plugins, and FFI packages (e.g., `mmkv`, `isar`) |
| Flutter SDK version | ❌ | Patches must be built with the exact same Flutter version as the baseline build |

## Quick Start

**1. Add dependency & initialize**

```bash
flutter pub add flutter_patcher
```

```dart
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await FlutterPatcher.init();
  runApp(const MyApp());
}

// Check for updates at an appropriate time. Without a url, checkUpdate uses
// the address `build` wrote into the app: `url` in flutter_patcher.yaml, or
// http://127.0.0.1:8686, where `serve` offers patches while developing.
final check = await FlutterPatcher.checkUpdate();
if (check.hasUpdate) {
  await FlutterPatcher.applyPatch(check.patch!);
}
```

**2. Build the release**

```bash
dart run flutter_patcher build android   # Or `build ios` (on an Apple Silicon Mac)
```

Install or ship the app `build` produces. `build` also records the baseline that every later patch of this build is made against.

**3. Fix bugs & make a patch**

```bash
dart run flutter_patcher patch android   # Writes <version_code>-<flavor>-<channel>-<abi>.fptc
dart run flutter_patcher serve           # Development: offers it at 127.0.0.1:8686 over USB
```

The patch is one `.fptc` file. In production, `publish` writes it to your store, and you put it where the app gets it: at `url` over HTTPS for `checkUpdate`, or anywhere your app fetches it from and passes it to `FlutterPatcher.applyPatchBytes`.

No keys or `flutter_patcher.yaml` are needed to start. Signing is optional and recommended: run `dart run flutter_patcher keys init` before the build you ship.

See the [Getting Started Guide](doc/getting-started.md) for the full walkthrough and the [Production Deployment Guide](doc/production-playbook.md) for going live.

## Caveats

- **Activation**: Installed patches take effect on the **next cold start**.
- **Keep Your Baselines**: Every patch of a build is made against the baseline `build` recorded. Set `baseline_store` to durable storage; a lost baseline means that build can no longer be patched.
- **Unsigned Hosts**: An app built without a signing key does not check where a patch comes from: whoever can hand it a patch file can run code in it. The built-in downloader enforces HTTPS; if your app fetches files itself, securing the transport is up to it, or enable signing.
- **Store Policies**: Some app stores restrict downloading executable code. Verify your distribution channel's policies before deploying.

## Documentation

| Document | Description |
|---|---|
| [Getting Started](doc/getting-started.md) | End-to-end guide from integration to applying your first patch |
| [How It Works](doc/architecture.md) | Host runtime, baselines, patching strategy, and security model |
| [CLI Reference](doc/cli.md) | Commands, flags, and `flutter_patcher.yaml` configuration |
| [API Reference](doc/api-reference.md) | Client-side Dart API reference |
| [Production Deployment Guide](doc/production-playbook.md) | From a local setup to a live app: hosting patch files, signing, withdrawing, rolling back, upgrading from 1.0 |
| [Advanced Operations](doc/advanced.md) | Less common setups and operations |
| [Crash Protection](doc/crash-protection.md) | Auto-rollback, patch blacklisting, and startup diagnostics |
| [Troubleshooting](doc/troubleshooting.md) | Error code reference and resolution guide |
| [FAQ](doc/faq.md) | Version alignment, cold starts, and store compliance |

## Contributing

Issues and Pull Requests are welcome. Please make sure all checks pass before submitting:

```bash
flutter pub get
flutter analyze
flutter test
```

When modifying native code, please also run the on-device acceptance tests in [`test/acceptance`](test/acceptance/README.md).

## License

[MIT](LICENSE)