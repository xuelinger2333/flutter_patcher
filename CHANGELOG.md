> Chinese version: [CHANGELOG-zh.md](CHANGELOG-zh.md)

## 1.0.0

1.0.0 rebuilds flutter_patcher around signed updates and a four-command
workflow. Apps on 0.1.x must be rebuilt and released once; 0.1.x patches and
the `pack` tool do not work with 1.0.0 hosts. See [Getting
Started](doc/getting-started.md).

### Added

- **iOS support.** `build ios` (on an Apple Silicon Mac) builds an iOS host;
  `patch ios` runs on Linux, Windows or macOS.
- **Bytecode patches**, the default strategy on Android and the only one on
  iOS: a patch carries only the changed code, which an interpreter in the
  engine runs while unchanged code stays machine code. Pure-Dart dependencies
  and assets can change too. `build android --strategy so` keeps the
  `libapp.so` replacement of 0.1.x, now with the same signed updates.
- **The command-line tool ships in this package**: `dart run flutter_patcher
  <command>`, always the version of the plugin the app resolved. In a project
  the usual workflow needs no flags:
  - `keys init` creates the root, publisher and patch key pairs: the private
    keys in the user's key store, the public keys in `flutter_patcher.yaml`,
    which belongs in version control. `keys export`, `keys import` and `keys
    status` move and inspect them;
  - `build android|ios` builds the host app and archives its baseline, and
    writes the host policy (application id, version, keys...) itself, with
    `url`, the address devices download patches from;
  - `patch android|ios` compares the source with the released baseline and
    writes an unsigned patch, rejecting changes a patch cannot carry (native
    code, FFI, removed assets...) with the reason. It needs no private key and
    no publication store. `publish` numbers patches 1, 2, 3... per release, or as `--seq` says;
  - `publish` reads the release's manifest at `url` before numbering, so
    numbering continues even if local records are lost, then signs the patch
    and writes it to the publication store after a preview; `publish
    --withdraw` withdraws all of the release's published patches; a publish
    interrupted while committing resumes on the next run;
  - `serve` publishes each new patch and serves it to a USB-connected Android
    device while developing;
  - `doctor` checks the toolchain.
- **Signed updates.** Devices install only patches signed with your keys,
  for exactly their app, version, flavor, channel and ABI, with a sequence
  above any they accepted; withdrawals are signed too. Storage and CDNs need
  not be trusted. The root key can replace the publisher key without a new
  release (`trust sign`, `trust publish`, `updatePublicationTrust`).
- **Keys outside the project.** `publish`, `serve` and `trust sign` take each
  private key from `--key-file`, the `FLUTTER_PATCHER_KEYS` environment
  variable (a CI secret), an external `signing.command` (a KMS or signing
  service) or the key store, and check it against the project's public keys.
- `applySignedManifest` and `fetchSignedManifest`, with `SignedManifest` and
  `SignedUpdateResult`, for apps that deliver manifests and patches
  themselves.
- `PatchBootStatus.bytecodeBootFailed` and `soBootFailed`: a start that failed
  before the crash threshold.
- Engines and tools come from immutable artifact releases recorded in each
  baseline, so a released app can always be patched with what it was built
  with.

### Changed

- Requires Flutter 3.47.0 (Dart 3.13.0) or later; Flutter 3.47.0 - 3.47.9
  are supported.
- `checkUpdate()` checks the `url` that `build` wrote into the app from
  `flutter_patcher.yaml` (`http://127.0.0.1:8686`, where `serve` offers
  patches, until it is set); `checkUpdate(url: ...)` checks another address.
  It verifies the signed manifest there. Pass the `PatchInfo` it returns to
  `applyPatch` unchanged.
- The Android plugin no longer applies the Kotlin Gradle plugin itself: on
  AGP 9 it compiles with AGP's built-in Kotlin, on AGP 8 with the app's
  Kotlin plugin. Kotlin targets JVM 17 either way.
- Patches apply on Android 9 (API 28) and later, in the app's main process;
  on Android 7-8 the app runs as built.
- Updates are fetched over HTTPS only, or plain HTTP from the device's own
  loopback address while developing; redirects are not followed.
- `lastBootDiagnostic` reports the current start: asked before a patched
  start's first frame, it waits for it, up to 10 seconds.
- `BlacklistEntry.version` identifies the patch as
  `<host fingerprint>:<sequence>:<patch SHA-256>`.

### Removed

- The 0.1.x update flow: `dart run flutter_patcher:pack` and the mock
  server; `applyPatchBytes`; the `publicKeyBase64`, `strictSignature` and
  `headers` parameters of `init` and `checkUpdate`; `PatchInfo.patchUrl`,
  `md5`, `signature`, `targetVersionCode`, `fromJson` and `toJson`;
  `PatchCheckResult.fromJson` and the JSON check-update protocol. An app not
  built with `flutter_patcher build` runs its original code, and
  `checkUpdate` throws `PatcherException` there.
- Values no 1.0.0 host reports: `PatchApplyError.md5Mismatch`,
  `unsupportedAbi` and `assetPackageInvalid`; `PatchBootStatus
  .droppedSignatureInvalid`, `droppedMd5Mismatch` and `droppedMetaCorrupted`;
  `BlacklistEntry.md5`. A blacklist entry's `reason` is always `BOOT_CRASH`.
- `FlutterPatcher.reportBootSuccess()`: the plugin confirms a start natively
  at its first frame.

### Migrating from 0.1.x

1. Raise Flutter to 3.47 and update the dependency to `flutter_patcher: ^1.0.0`.
2. Run `dart run flutter_patcher keys init`, commit `flutter_patcher.yaml` and
   back up the private keys with `keys export --out <file>`.
3. Build the app with `dart run flutter_patcher build android` and release it.
4. Set `url` in `flutter_patcher.yaml` to the address where your publication
   store is served, call `checkUpdate()` (see the
   [Production Playbook](doc/production-playbook.md)), and make patches with
   `patch` and `publish`.

## 0.1.4

### Fixed

- Fixed the Android build failing on host apps that use AGP 9 built-in
  Kotlin, with `Failed to apply plugin 'kotlin-android'` followed by
  `project ':flutter_patcher' does not specify compileSdk`. This affects
  projects created with or migrated to Flutter 3.44, which ship AGP 9.
  `android/build.gradle` now checks whether built-in Kotlin is actually
  active on the host and applies the Kotlin Gradle Plugin, plus the
  matching jvmTarget DSL, only where that DSL exists: `kotlinOptions` when
  KGP is applied, `kotlin { compilerOptions }` under built-in Kotlin.

  The switch is built-in Kotlin, not the AGP major version. AGP 9 hosts
  that opt out with `android.builtInKotlin=false` (the default the Flutter
  3.44 template generates) still need the plugin to bring its own KGP,
  exactly like AGP 8 hosts, and keep the previous code path unchanged.

  This is a build-time only change, with no runtime behavior change.
  Patches remain fully compatible: payloads produced by or for 0.1.3
  install and boot identically on 0.1.4, and no repack is required.

- No change to the minimum supported Flutter or AGP version. Existing
  hosts on AGP 8 build exactly as before.

### Known issues

- On AGP 9 hosts, Flutter still prints `WARNING: Your app uses the
  following plugins that apply Kotlin Gradle Plugin (KGP):
  flutter_patcher`. The Flutter Gradle Plugin decides this by text-matching
  `android/build.gradle`, so it cannot see that the `apply plugin` line is
  guarded. The warning is safe to ignore, and the literal has to stay:
  when the Flutter Gradle Plugin finds no KGP declaration in a plugin, it
  applies `kotlin-android` to that plugin itself, which fails the build
  under built-in Kotlin.
- Flutter 3.44's own Gradle plugin does not support `android.newDsl=true`
  and fails to apply before any plugin is evaluated. Keep the template
  default `android.newDsl=false`.

## 0.1.3

### Added

- Added Android cold-start Flutter asset hot updates. Assets (images,
  fonts, JSON, anything reachable via `Image.asset(...)` or
  `rootBundle.load(...)`) can be patched together with Dart code through
  the same `patch.zip` payload.
- Added `--assets` to `dart run flutter_patcher:pack`. Pass paths inline
  (`--assets a,b`) or read them from a UTF-8 text file with the `@` prefix
  (`--assets @patch-assets.txt`, one path per line, `#` starts a comment);
  inline paths and `@file` references can be mixed in the same flag.
  Each path must already be registered under `assets:` in the new APK's
  `pubspec.yaml`; `--assets` only tells `pack` which of those assets to
  ship inside `patch.zip`. The runtime overlays them on top of the APK's
  Flutter asset bundle at install time.

### Changed

- `dart run flutter_patcher:pack` now always emits `dist/patch.zip` +
  `dist/manifest.json` (outer `schemaVersion: 2`, `payload: patch.zip`),
  whether or not `--assets` is passed. A Dart-only `patch.zip` contains
  just `manifest.json` + `lib/<abi>/libapp.so`; its inner manifest omits
  the `assets` block. The previous bare-`.so` output mode is gone.
- Android runtime detects ZIP payloads, installs overlay asset packages,
  builds a private `flutter_assets.apk`, and starts Flutter through a
  patched `FlutterJNI` AssetManager when assets are present. Dart-only
  `patch.zip` payloads short-circuit the asset overlay pipeline and
  behave like code-only patches at install time.
- `mock_server --dist` reads `manifest.payload` and serves the declared
  file.

### Compatibility

- Bare-`.so` patches produced by 0.1.0-0.1.2 still install on 0.1.3
  devices (the runtime keeps a quiet legacy install path); the producer
  CLI no longer emits that format. Server operators should ship
  `patch.zip` for any new patch built against a 0.1.3+ host APK.

## 0.1.2

### Added

- Added `dart run flutter_patcher:mock_server` for local
  `checkUpdate -> applyPatch` testing without maintaining an example-only
  helper script.

### Changed

- Improved README onboarding with a TL;DR, clearer fit / non-fit guidance,
  store policy warning, and local mock server instructions.
- Updated pub.dev package description and topics for better discoverability.
- Added a GitHub social preview image under `doc/social-preview.png`.

## 0.1.1+1

### Fixed

- Corrected the README install snippet version pin to `^0.1.1`
  (docs-only, no code change).
- Translated CHANGELOG to English so pub.dev's pana check no longer
  flags it for non-ASCII content. Chinese version preserved as
  `CHANGELOG-zh.md`.

## 0.1.1

### Changed

- **`PatchInfo.md5` is now optional.** An empty string means the caller
  explicitly opts out of download integrity verification and relies on
  HTTPS only. When `md5` is empty the Ed25519 signature check is also
  skipped (the signature input is the md5 hex, so no md5 means no
  signature input). `toJson` omits the `md5` key when it is empty.
- **`validatePatchArgs`**: blank `md5` is now accepted; non-blank `md5`
  is still required to be 32 lowercase hex chars.
- **Blacklist**: when the caller does not provide `md5`, the download
  pre-check falls back to version-only matching via the new
  `BlacklistStore.containsByVersion`. Blacklist entries are still
  recorded with the actual md5 computed after download.
- **`meta.json`**: `effectiveMd5` now always stores the md5 computed
  after download (previously it stored the server-declared md5). Boot
  checks and blacklist entries key on this stable hash.
- **Dependency constraints relaxed**: Dart SDK constraint changed from
  `^3.10.7` to `>=3.0.0 <4.0.0`; runtime dependencies switched to a
  lower bound plus an open upper bound; `archive` now supports both
  3.x and 4.x to reduce host-project conflicts.

## 0.1.0

First public release (Android-only beta).

### Core features

- **Cold-start hot updates**: replaces `FlutterLoader.findAppBundlePath`
  via reflection inside `Application.attachBaseContext`, before the
  Dart engine starts, enabling whole-file `libapp.so` replacement.
- **Signature verification**: built-in Ed25519 (X.509 SubjectPublicKey
  Info) plus MD5 dual verification, with `strictSignature` mode that
  prevents downgrade bypass on older devices.
- **Crash circuit breaker / auto rollback**: counts `REASON_CRASH`
  events from `ApplicationExitInfo` and hooks
  `PlatformDispatcher.onError` on the Dart side. Once `maxCrashCount`
  (default 1, fail-fast) is reached, the patch is deleted, added to
  the blacklist, and the host falls back to the bundled APK version.
- **First-frame verify clears the breaker**: after the patch loads,
  the app must stay alive in the foreground for `verifyAfter`
  (default 5s) before being marked verified, which resets the crash
  counter.
- **Local blacklist**: auto-blacklisted patches will never be
  reinstalled, preventing crash loops. Inspect or clear via
  `FlutterPatcher.blacklist` / `clearBlacklist`.
- **Progress event stream**: `FlutterPatcher.applyProgress` exposes
  `downloading` / `verifying` / `finalizing` phase events.
- **CLI packaging tool**: `dart run flutter_patcher:pack` extracts
  `libapp.so` from a release APK and produces the patch manifest.

### Known limitations

- **Android only**. On iOS / Web / desktop, all APIs are no-ops (the
  first call prints a warning).
- **Strict Ed25519 mode requires Android API 33+**. Below API 33 with
  `strictSignature: true` (the default), signed patches are rejected.
- **Only full-mode patches are supported**. Differential patching is
  not shipped in 0.1.0 to avoid exposing an unverified path.
- This initial release shipped the legacy lib-only payload path. Asset
  payloads were added later in 0.1.3.

### Documentation

- Repository README: use cases, 5-minute demo, integration steps.
- `doc/architecture.md`: native + Dart layered architecture and
  startup sequence.
- `doc/api-reference.md`: full API reference.
- `doc/crash-protection.md`: breaker and rollback strategy.
