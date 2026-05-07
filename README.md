# flutter_patcher

**English** | [简体中文](README-zh.md)

[![Platform](https://img.shields.io/badge/platform-Android_only-brightgreen)](https://flutter.dev)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Status](https://img.shields.io/badge/status-beta-orange)]()

Hot-update plugin for Flutter on Android.
By delivering a `libapp.so` patch, your Dart code changes take effect on the next cold start, and the plugin automatically rolls back if a patch fails to boot.

> The project is in beta. Validate it in internal testing, staged rollouts and non-critical paths before using it in production.

---

## Features

- Hot updates for Flutter Dart code on Android
- Patches take effect on cold start, no runtime intrusion
- Self-hosted distribution; no third-party cloud lock-in
- Built-in integrity verification, crash rollback, and a bad-patch blacklist
- Ships with a packaging CLI, runtime diagnostics, and a sample app

---

## Table of contents

- [Is this plugin a fit for you?](#is-this-plugin-a-fit-for-you)
- [Requirements](#requirements)
- [5-minute walkthrough](#5-minute-walkthrough)
- [Install](#install)
- [Quick start](#quick-start)
- [Patch lifecycle](#patch-lifecycle)
- [Crash protection](#crash-protection)
- [What can and cannot be patched](#what-can-and-cannot-be-patched)
- [Security](#security)
- [Production recommendations](#production-recommendations)
- [FAQ](#faq)
- [Documentation](#documentation)

---

## Is this plugin a fit for you?

`flutter_patcher` is a self-hosted Android-only hot-update SDK for Flutter.
Patches live on your own server, CDN, or object storage; nothing depends on a third-party cloud.

### Good fit

- Your project only needs Android hot updates; iOS can ship through normal store releases
- Your team can run its own patch distribution, and patch data must be self-hosted
- You want to roll out Dart-layer fixes to a small audience quickly

### Not a fit

- You need hot updates on both Android and iOS
- You don't want to maintain any patch-distribution infrastructure
- You need a commercial SLA, hosted console, audit trails, or dedicated support
- You need to update native code, Android resources, assets, or the Flutter Engine
- App-store policy or regulatory rules forbid dynamic delivery of executable code

If you need cross-platform hot updates or a managed service, evaluate alternatives such as Shorebird.

---

## Requirements

| Item | Requirement |
|---|---|
| Platform | Android only |
| Dart SDK | `>=3.0.0 <4.0.0` |
| Flutter | `>=3.3.0`; loader hook verified on 3.19 ~ 3.38 |
| Android `minSdk` | 24 |
| Android `compileSdk` | 36 |
| ABI | `armeabi-v7a` / `arm64-v8a` / `x86_64` |
| NDK | 27.0.12077973+ |
| AGP | 8.11.1+ |
| Kotlin | 2.2.20+ |
| Java / JVM | 17 |

On iOS, macOS, Windows, Linux and Web, every API is safe to call but does nothing — the plugin logs a one-time "platform unsupported" warning and returns safe defaults.

---

## 5-minute walkthrough

You don't need any backend. Clone the repo and you can experience the full hot-update flow:

```bash
git clone https://github.com/user/flutter_patcher.git
cd flutter_patcher/example
flutter build apk --release
flutter install
```

Steps:

1. Launch the app — the button is **blue**
2. Tap **Apply patch**
3. Swipe the app away from recents and reopen it
4. The button is now **red** — the patch took effect
5. Tap **Rollback**
6. After another restart it is blue again

The example bundles a precompiled red-theme patch.
`Apply patch` reads the asset bytes and calls `applyPatchBytes`; the entire flow is offline.

---

## Install

```yaml
dependencies:
  flutter_patcher: ^0.1.1
```

Or as a Git dependency:

```yaml
dependencies:
  flutter_patcher:
    git:
      url: https://github.com/user/flutter_patcher.git
```

---

## Quick start

### 1. Initialize

Call before `runApp()`:

```dart
void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await FlutterPatcher.init();

  runApp(const MyApp());
}
```

The defaults are appropriate for most projects.

If you need to tune crash protection, pass parameters explicitly:

```dart
await FlutterPatcher.init(
  maxCrashCount: 1,
  verifyAfter: const Duration(seconds: 5),
);
```

### 2. Apply a patch

The client only needs a `PatchInfo`; pass it to `applyPatch`. `PatchInfo` is normally produced from your own update endpoint:

```dart
final result = await FlutterPatcher.applyPatch(
  PatchInfo(
    version: 'fix-1',
    patchUrl: 'https://your-cdn.com/v100/libapp.so',
    md5: '0123456789abcdef0123456789abcdef',
    targetVersionCode: 100,
  ),
);

if (result.ok) {
  // The patch will take effect on the next cold start; show a restart hint if you want.
}
```

> The plugin also ships with an optional minimal check-update JSON protocol, intended for quick onboarding, the example, and local testing. In production, if you already have your own update / staging / auth protocol, parse the response yourself and construct `PatchInfo` directly. The protocol format and `checkUpdate` usage live in the [API reference](https://pub.dev/documentation/flutter_patcher/latest/topics/API-reference-topic.html) and [Architecture](https://pub.dev/documentation/flutter_patcher/latest/topics/Architecture-topic.html).

> **Skipping MD5**: `PatchInfo.md5` is now optional. If your server doesn't ship md5 (or you only want HTTPS-level integrity), leave it out:
> ```dart
> PatchInfo(version: 'fix-1', patchUrl: '...', targetVersionCode: 100); // md5 defaults to ''
> ```
> Download integrity checks are skipped; **note that signature verification is also skipped** in this case (the Ed25519 input is the md5 hex string — without md5 there is no message to sign over). To keep signature verification you must also ship md5.

### 3. Apply a patch from in-memory bytes

If you already have your own download logic, or the patch comes from an asset / isolate, use `applyPatchBytes`:

```dart
final bytes = await loadPatchFromYourSource();

final result = await FlutterPatcher.applyPatchBytes(
  bytes,
  version: '1.0.0-h1',
  targetVersionCode: 100,
);
```

`applyPatchBytes` automatically computes the MD5, manages the temporary file, and reuses the regular apply flow.

### 4. Build a patch

Every patch is bound to a base APK.
`--target-version-code` declares which installed APK `versionCode` the patch applies to.

Note: `--target-version-code` is **not** the patch version, and not the patch APK's version — it's the `versionCode` of the base APK already installed on the user's device.

For example, if your live APK has `versionCode = 100` and you're building hotfix `1.0.0-h1` for that version:

```bash
# Rebuild the release APK after editing Dart code
flutter build apk --release

# Extract the patch from the new APK; the base version is versionCode = 100
dart run flutter_patcher:pack \
  --apk build/app/outputs/flutter-apk/app-release.apk \
  --version 1.0.0-h1 \
  --target-version-code 100
```

Output:

```text
dist/
├── libapp.so
└── manifest.json
```

Upload `libapp.so` and `manifest.json` to your CDN or object storage.

For the server protocol, signature workflow, disabling auto-init and other advanced configuration, see [Architecture](https://pub.dev/documentation/flutter_patcher/latest/topics/Architecture-topic.html).

### 5. Roll back

```dart
await FlutterPatcher.rollback();
```

Rollback deletes the current patch. On the next cold start the app falls back to the version baked into the APK.

A manual `rollback()` does **not** add the patch to the blacklist.

---

## Patch lifecycle

```text
Download patch
  ↓
Verify MD5 / signature when provided, then versionCode
  ↓
Persist to local patch directory
  ↓
Wait for the next cold start
  ↓
Cold start loads the patched libapp.so
  ↓
Boot succeeds: keep using the patch
Boot fails:    auto-rollback
```

A successful `applyPatch` takes effect on the **next cold start**, never inside the current process.

If you need to nudge users to restart, show a prompt after `applyPatch` succeeds.

---

## Crash protection

`flutter_patcher` is fail-fast by default.
If a patch causes a boot failure, or a serious Dart-level error fires during early UI, the plugin rolls back to the APK's built-in version on the next cold start and adds the offending patch to a local blacklist, so the same bad patch is not loaded over and over.

Common settings:

| Parameter | Default | Description |
|---|---|---|
| `maxCrashCount` | `1` | Number of consecutive failures before the patch is tripped |
| `verifyAfter` | `5 seconds` | Window during which the post-first-frame Dart error hooks keep watching |

Android 11+ uses `ApplicationExitInfo` to distinguish crashes, ANRs, user dismissal, and system reclaim more accurately.
Android 10 and below have weaker signals; pair the SDK with your own crash monitoring and a server-side kill switch.

The full design, Android version differences, blacklist semantics, and diagnostic states live in the [Crash protection](https://pub.dev/documentation/flutter_patcher/latest/topics/Crash-protection-topic.html) doc.

---

## What can and cannot be patched

The plugin only replaces the Dart compilation artifact `libapp.so`.

### Hot-patchable

- Dart code under `lib/`
- Widgets and page logic
- Business logic
- State management
- Routing
- String constants
- Pure-Dart third-party package upgrades, as long as the native side is unchanged

### Not hot-patchable

The following must go through a regular release:

- Kotlin / Java / C++ or other native code
- AndroidManifest changes
- Android resources
- Flutter assets (images, fonts, JSON, …)
- Flutter Engine upgrades
- Adding or modifying native plugins

### Evaluate carefully

- ProGuard / R8 changes: a mismatched symbol map can make crash stacks unreadable
- Multi-ABI / multi-flavor: the server must distribute by `ABI × flavor × versionCode`
- Breaking Dart API changes: persisted data may be incompatible with old code after rollback
- Database schema or local cache format changes: both old and new code must read safely

---

## Security

`flutter_patcher` provides basic integrity checks plus an optional signature mechanism.

- MD5 verification is strongly recommended; leave `PatchInfo.md5` empty only for quick testing or protocols that intentionally rely on HTTPS-level integrity
- Optional Ed25519 signature verification; because the signed message is the md5 hex string, signatures are only checked when `md5` is present
- Keep the private key on the server or build environment only — never in the client repo
- A patch is strongly bound to the host APK's `versionCode`, so old patches expire after an APK upgrade
- Always download patches over HTTPS
- The server should record patch version, MD5/signature when used, target `versionCode`, and release time

For signature generation, `strictSignature` behavior, and the server protocol, see [Architecture](https://pub.dev/documentation/flutter_patcher/latest/topics/Architecture-topic.html).

---

## Production recommendations

### 1. Stage the rollout

Don't ship a patch to 100% on day one. A typical ramp:

```text
1% → 5% → 20% → 50% → 100%
```

Watch crash rate, boot failure rate, and the key business metrics at each stage.

### 2. Report boot diagnostics

Report `lastBootDiagnostic`:

```dart
final diag = await FlutterPatcher.lastBootDiagnostic;

if (diag != null && !diag.isHealthy) {
  // Replace with your analytics SDK: Firebase Analytics / Sentry / your own pipeline.
  analytics.report('patch_dropped', {
    'status': diag.status.name,
    'patch_version': diag.patchVersion,
    'crash_count': diag.crashCount,
    'message': diag.message,
  });
}
```

If the same patch triggers `droppedCircuitBreaker` repeatedly in a short window, the server should automatically stop delivering it.

### 3. Keep release records

Track each patch with at least:

- Patch version
- Target APK `versionCode`
- ABI
- Flavor
- MD5, if shipped
- Signature, if shipped
- Release time
- Rollout percentage
- Current state: ramping, full, or rolled back

### 4. Plan for emergency rollback

An emergency rollback only requires the update endpoint to stop returning the offending patch version.
Devices that already tripped crash protection have rolled back locally and will refuse to apply the same problematic patch again.

---

## FAQ

### Q: Must the patch and base APK use the same Flutter version?

A: Yes. `libapp.so` is tightly coupled to the Flutter Engine and Dart runtime. Different Flutter versions cannot safely load each other's `libapp.so`. After upgrading the Flutter SDK or Engine, you must ship a new release.

### Q: A user skipped intermediate patch versions and just got the latest one — what happens?

A: Each patch is a complete `libapp.so` and does not depend on previous patches. Users can jump straight from "no patch" or an old patch to the latest one.

### Q: How do I iterate quickly during development without uploading to a CDN?

A: Use a `file://` URL pointing at a local device path, or use the bundled mock server. Note that `mock_server.dart` depends on the `crypto` `dev_dependency` declared in `example/`, and must be run from the `example/` directory:

```bash
cd example
flutter pub get

dart run flutter_patcher:pack \
  --apk path/to/app-release.apk \
  --version dev-1 \
  --target-version-code 1

dart run tools/mock_server.dart dist 8080
```

Set the client `patchUrl` to:

```text
http://<your-machine-ip>:8080/libapp.so
```

### Q: How do I handle multiple ABIs?

A: The server must distribute a `libapp.so` per ABI. The client can read the current device ABI via `FlutterPatcher.deviceAbi` and include it in your update request.

### Q: How do I handle multiple flavors?

A: The server should track patches by `flavor × ABI × versionCode`. Different flavors typically have different configs, package names, resources, and business logic — never share a patch across flavors.

### Q: Do I need to tweak ProGuard / R8 rules?

A: Usually no. The plugin's reflection targets non-obfuscated Flutter Engine classes and is unaffected by your business obfuscation.

### Q: Can a patch be revoked?

A: Yes. On the client, `FlutterPatcher.rollback()` deletes the current patch. On the server, simply stop returning that version from your update endpoint and new users will not download it.

### Q: Why doesn't a patch take effect immediately?

A: Once the current process has loaded `libapp.so`, it can't be safely swapped at runtime. To stay safe, the patch is written to disk and loaded on the next cold start.

### Q: Why does each patch need a `targetVersionCode`?

A: A patch is only valid against the base APK it was built for. Binding `targetVersionCode` prevents loading old patches after an APK upgrade and prevents the server from accidentally shipping a patch to incompatible builds.

---

## Documentation

- [API reference](https://pub.dev/documentation/flutter_patcher/latest/topics/API-reference-topic.html) — init, check-update, apply, rollback, diagnostics, error codes, and CLI flags
- [Crash protection](https://pub.dev/documentation/flutter_patcher/latest/topics/Crash-protection-topic.html) — crash protection, auto-rollback, blacklist, Android version differences, and diagnostic states
- [Architecture](https://pub.dev/documentation/flutter_patcher/latest/topics/Architecture-topic.html) — internals, self-hosted server protocol, signing, and advanced configuration

中文文档：[README-zh.md](README-zh.md) · [doc/api-reference-zh.md](doc/api-reference-zh.md) · [doc/architecture-zh.md](doc/architecture-zh.md) · [doc/crash-protection-zh.md](doc/crash-protection-zh.md)

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
