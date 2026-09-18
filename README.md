# flutter_patcher

**English** | [简体中文](README-zh.md)

The development CLI defaults to bytecode: lean first, with checked whole fallback.
Android bootstrap automatically prefers available FFI and preserves the app's
Binding. SO continues through the existing v1 workflow. See
[default paths and fallback rules](doc/default-paths.md).

[![pub package](https://img.shields.io/pub/v/flutter_patcher.svg)](https://pub.dev/packages/flutter_patcher)
[![Platform](https://img.shields.io/badge/platform-Android-brightgreen)](https://flutter.dev)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

Open-source, self-hosted **code push** for Flutter Android.
Ship Dart code and asset hotfixes over the air — no store release, no third-party cloud.

If you've used [Shorebird](https://shorebird.dev/), [CodePush](https://learn.microsoft.com/en-us/appcenter/distribution/codepush/), or [Expo EAS Update](https://docs.expo.dev/eas-update/introduction/) — flutter_patcher brings the same OTA update model to Flutter Android, fully self-hosted and MIT-licensed.

![Feature demo: apply a patch, cold restart, and rollback](doc/feature-presentation.gif)

---

## How it compares

|                | flutter_patcher          | Shorebird                     | CodePush (React Native)       |
|----------------|--------------------------|-------------------------------|-------------------------------|
| Framework      | Flutter                  | Flutter                       | React Native                  |
| Platforms      | Android                  | Android + iOS                 | Android + iOS (retired 2025)  |
| Hosting        | Your server / CDN        | Shorebird cloud               | AppCenter cloud (deprecated)  |
| Update scope   | Dart code + assets       | Dart code (engine-level diff) | JS bundle                     |
| Takes effect   | Next cold start          | Next restart                  | Next restart                  |
| Cost           | Free (MIT)               | Free tier + paid plans        | —                             |
| Self-hostable  | Yes — full control       | Cloud-managed                 | —                             |

**Choose Shorebird** if you need iOS support or a fully managed service.
**Choose flutter_patcher** if you need self-hosted OTA updates on infrastructure you control — enterprise apps, regional distribution, or non-Play channels.

> Google Play and some stores restrict downloading executable code at runtime. flutter_patcher targets self-controlled, enterprise, or permissive distribution channels. Check your channel's policy before shipping.

---

## Features

- **OTA code push** — replace Dart AOT `libapp.so` and Flutter assets on the next cold start
- **Self-hosted** — patches live on your CDN / object storage / internal server; zero vendor lock-in
- **Integrity verification** — MD5 checksum + optional Ed25519 signature (Android 13+)
- **Crash rollback** — automatic rollback on boot failure with a bad-patch blacklist
- **Tooling included** — `pack` CLI, runtime diagnostics, local mock server, and sample app

---

## Try it in 5 minutes

No server needed. Clone and experience the full patch → restart → rollback flow:

```bash
git clone https://github.com/xuelinger2333/flutter_patcher.git
cd flutter_patcher/example
flutter build apk --release
flutter install
```

1. Launch the app — it shows the **original** `assets/patch_demo.png`
2. Tap **Apply patch**
3. Swipe the app away from recents and reopen it
4. The image has changed — the asset patch took effect
5. Tap **Rollback** → restart → original image is back

The example bundles a precompiled `patch.zip`. Everything runs offline on the device.

For HTTP-based testing, see the [Local mock server guide](doc/getting-started.md#local-mock-server).

---

## Requirements

| Item | Requirement |
|---|---|
| Platform | Android only |
| Dart SDK | `>=3.0.0 <4.0.0` |
| Flutter | `>=3.3.0`; loader hook verified on 3.19 ~ 3.44 |
| Android `minSdk` | 24 |
| Android `compileSdk` | 36 |
| ABI | `armeabi-v7a` / `arm64-v8a` / `x86_64` |
| NDK | 27.0.12077973+ |
| AGP | 8.11.1+ (including AGP 9.x) |
| Kotlin | 2.2.20+ (or AGP 9 built-in Kotlin) |
| Java / JVM | 17 |

On iOS, macOS, Windows, Linux, and Web, every API is safe to call but does nothing — the plugin logs a one-time warning and returns safe defaults.

---

## Quick start

### 1. Install

```yaml
dependencies:
  flutter_patcher: ^0.1.4
```

Or as a Git dependency:

```yaml
dependencies:
  flutter_patcher:
    git:
      url: https://github.com/xuelinger2333/flutter_patcher.git
```

### 2. Initialize

Call before `runApp()`:

```dart
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await FlutterPatcher.init();
  runApp(const MyApp());
}
```

### 3. Build a patch

Rebuild the release APK, then run `pack`:

```bash
dart run flutter_patcher:pack \
  --apk build/app/outputs/flutter-apk/app-release.apk \
  --version 1.0.0-h1 \
  --target-version-code 100
```

To include assets (since 0.1.3), append `--assets`:

```bash
dart run flutter_patcher:pack \
  --apk build/app/outputs/flutter-apk/app-release.apk \
  --version 1.0.1 \
  --target-version-code 100 \
  --assets assets/hero.png,assets/strings/zh.json
```

- `--version`: patch version (any string).
- `--target-version-code`: the `versionCode` of the **base APK installed on the user's device**.
- `--assets`: asset paths to include in `patch.zip`. Each must be registered in the new APK's `pubspec.yaml`.

Output: `dist/patch.zip` + `dist/manifest.json`. Upload `patch.zip` to your CDN and have your update endpoint return a `PatchInfo` pointing at it.

For advanced `--assets` syntax and the `@file` list format, see [API Reference](doc/api-reference.md#asset-patching).

### 4. Apply a patch

```dart
final result = await FlutterPatcher.applyPatch(
  PatchInfo(
    version: 'fix-1',
    patchUrl: 'https://your-cdn.com/v100/patch.zip',
    md5: '0123456789abcdef0123456789abcdef',
    targetVersionCode: 100,
  ),
);

if (result.ok) {
  // Patch takes effect on next cold start
}
```

If you manage downloads yourself, use `applyPatchBytes`:

```dart
final bytes = await loadPatchFromYourSource();
final result = await FlutterPatcher.applyPatchBytes(
  bytes,
  version: '1.0.0-h1',
  targetVersionCode: 100,
);
```

### 5. Roll back

```dart
await FlutterPatcher.rollback();
```

Deletes the current patch. The app reverts to the APK's built-in version on the next cold start.

---

## How it works

```text
Download patch
  ↓
Verify MD5 / signature (when provided), then versionCode
  ↓
Persist to local patch directory
  ↓
Next cold start → load patched libapp.so + asset overlays
  ↓
Boot succeeds → keep using the patch
Boot fails    → auto-rollback + blacklist
```

Patches take effect on the **next cold start**, never inside the running process.

---

## What can be patched

| Hot-patchable | Not hot-patchable |
|---|---|
| Anything in `lib/` — widgets, logic, routes, constants | Native code (Kotlin / Java / C++), `AndroidManifest.xml`, APK `res/` |
| Pure-Dart package upgrades (native side unchanged) | Flutter Engine upgrades |
| Flutter asset files (registered in `pubspec.yaml` + listed in `--assets`) | Adding or removing native plugins |
| Existing `Image.asset()` / `rootBundle.load()` calls pick up new bytes automatically | Removing assets that exist in the base APK |
|  | `pubspec.yaml` font registration changes |

For edge cases (ProGuard/R8, multi-ABI/flavor, state migrations), see [API Reference](doc/api-reference.md#what-can-and-cannot-be-patched).

---

## Safety

### Crash protection

The plugin is fail-fast by default. If a patch causes a boot failure, it auto-rolls back and blacklists the offending version so it won't be retried. Configurable via `maxCrashCount` (default 1) and `verifyAfter` (default 5s).

Full design and Android version differences: [Crash protection docs](https://pub.dev/documentation/flutter_patcher/latest/topics/Crash-protection-topic.html).

### Integrity & signing

- **MD5** verification is strongly recommended; omit only for quick testing
- **Ed25519 signature** verification is available on Android 13+ (API 33)
- Patches are bound to the host APK's `versionCode` — old patches expire after an APK upgrade
- Always download over HTTPS; keep private keys on the server only

Details: [Architecture → Security](https://pub.dev/documentation/flutter_patcher/latest/topics/Architecture-topic.html).

---

## Production tips

- **Stage your rollout** (1% → 5% → 20% → 50% → 100%) and monitor crash rate at each stage
- **Report diagnostics** — send `FlutterPatcher.lastBootDiagnostic` to your analytics pipeline
- **Prepare for emergency rollback** — stop returning the bad patch from your endpoint; devices that already tripped crash protection have rolled back locally

For a detailed production playbook with diagnostic reporting code and release record templates, see [Production Playbook](doc/production-playbook.md).

---

## FAQ

**Must the patch and base APK use the same Flutter version?**
Yes. `libapp.so` is tightly coupled to the Flutter Engine. After upgrading the SDK, ship a new release.

**Why doesn't a patch take effect immediately?**
Once `libapp.so` is loaded by the current process, it can't be swapped at runtime. The patch is written to disk and loaded on the next cold start.

**Why does each patch need a `targetVersionCode`?**
To prevent old patches from loading after an APK upgrade, and to prevent the server from shipping patches to incompatible builds.

More questions: [Full FAQ](doc/faq.md)

---

## Documentation

- [API Reference](https://pub.dev/documentation/flutter_patcher/latest/topics/API-reference-topic.html) — init, check-update, apply, rollback, diagnostics, error codes, CLI flags
- [Crash Protection](https://pub.dev/documentation/flutter_patcher/latest/topics/Crash-protection-topic.html) — auto-rollback, blacklist, Android version differences
- [Architecture](https://pub.dev/documentation/flutter_patcher/latest/topics/Architecture-topic.html) — internals, server protocol, signing, advanced config
- [Getting Started](doc/getting-started.md) — mock server, multi-ABI setup, step-by-step guides
- [Production Playbook](doc/production-playbook.md) — staged rollout, diagnostics, emergency rollback
- [FAQ](doc/faq.md) — common questions about versioning, cold start, and store policy

中文文档：[README-zh.md](README-zh.md) · [doc/api-reference-zh.md](doc/api-reference-zh.md) · [doc/architecture-zh.md](doc/architecture-zh.md) · [doc/crash-protection-zh.md](doc/crash-protection-zh.md)

---

## Who's using it?

If you run flutter_patcher in production, [open an issue](https://github.com/xuelinger2333/flutter_patcher/issues) and tell us about your use case — we'd love to list you here.

---

## Contributing

Issues and PRs are welcome.

Before submitting, please make sure:

- `flutter analyze` reports no warnings
- `flutter test` is fully green
- If you touched native code, you have run a real-device end-to-end patch / rollback flow

---

## License

MIT
