> Chinese version: [CHANGELOG-zh.md](CHANGELOG-zh.md)

## 1.1.1

1.1.1 lets `build` and `patch` take defines (`--dart-define`). Daily
development keeps using `flutter run` and `flutter build`; flutter_patcher
comes in only to build a host and to make a patch.

### `build` takes defines and `flutter build` options

**Added** · CLI · 2026-11-12 · flutter_patcher 1.1.1

- `build` takes `--dart-define` (`-D`) and `--dart-define-from-file` (JSON or
  `.env`) and merges them as `flutter build` does. Names and values are kept
  in the baseline as plain text.
- Options after `--` are passed to `flutter build`. Only options that do not
  affect patches are accepted, such as `--android-project-arg`; any other is
  refused with `BUILD_CONFIG_INVALID`.
- The defines `flutter build` sets itself (`FLUTTER_APP_FLAVOR`,
  `FLUTTER_BUILD_NAME`, `FLUTTER_BUILD_NUMBER`, `FLUTTER_VERSION` and others)
  are set by `build` and kept in the baseline; they cannot be passed.

Docs: [Defines and `flutter build` options](doc/cli.md#defines-and-flutter-build-options)

### A patch can change or add defines

**Added** · CLI · 2026-11-12 · flutter_patcher 1.1.1

- `patch` takes `--dart-define` and `--dart-define-from-file`: a define you
  pass is one this patch changes or adds, and every other define has the
  value the host was built with. A define cannot be removed.
- Every patch starts from the host's values, whatever earlier patches passed.
  A changed define is part of its patch and goes with it when the patch is
  withdrawn, rolled back or replaced.
- `patch` fails with `PATCH_DEFINE_UNREAD` when no Dart source reads a define
  you pass. A patch can change defines and no source.
- `defines` in the report names the defines changed and added.

Docs: [patch](doc/cli.md#patch)

### A patch is built from its host's build inputs

**Changed** · CLI · 2026-11-12 · flutter_patcher 1.1.1

- Before: a patch was compiled with `FLUTTER_APP_FLAVOR` alone; an SO patch
  was rebuilt with `FLUTTER_BUILD_NAME` from the current `version` in
  `pubspec.yaml`; `patch` needed the host's `--target`.
- Now: the entry file, the defines, the defines `flutter build` sets itself
  and the options after `--` are kept in the baseline, and patches of both
  strategies are compiled with them. `patch` needs no `--target`; a
  `--target` other than the host's, or a `version` in `pubspec.yaml` when the
  host was built without one, fails with `PATCH_BUILD_INPUTS_MISMATCH`. Hosts
  and patches are built with the Flutter feature flags `windowing` and
  `accessibility_evaluations` off.
- To keep the previous behavior: not possible in 1.1.1. Hosts built with
  1.1.0 keep being patched with flutter_patcher 1.1.0.

Docs: [patch](doc/cli.md#patch)

### `isAvailable`; `checkUpdate` reports no update in an app that takes no patches

**Changed** · Runtime · 2026-11-12 · flutter_patcher 1.1.1

- Before: in an app started with `flutter run` or built with `flutter build`,
  `checkUpdate` threw `PatcherException`.
- Now: `checkUpdate` reports no update and sends no request. The new
  `FlutterPatcher.isAvailable` tells whether this app can take patches.
  `patchTarget` and `inspectPatch` still throw.
- To keep the previous behavior: check `isAvailable` first.

Docs: [isAvailable](doc/api-reference.md#isavailable)

### `fromEnvironment` read no define in a bytecode patch

**Fixed** · CLI · 2026-11-12 · flutter_patcher 1.1.1

- Before: a bytecode patch was compiled with no defines at all, so
  `String.fromEnvironment`, `bool.fromEnvironment` and `int.fromEnvironment`
  called directly in the libraries a patch carries gave their defaults,
  `dart.vm.product` and `FLUTTER_APP_FLAVOR` included. Constants read through
  the Flutter framework, such as `kReleaseMode` and `appFlavor`, were not
  affected, and neither were SO patches.
- Now: a bytecode patch is compiled with its host's defines. The fix is in
  newly published compiler tools, which hosts built with 1.1.1 use; hosts
  built with 1.1.0 keep being patched with 1.1.0, without this fix.

### Other changes in 1.1.1

**Changed** · CLI · 2026-11-12 · flutter_patcher 1.1.1

- Hosts shipped with 1.1.0 keep being patched with flutter_patcher 1.1.0: in
  that release's code, `pubspec.yaml` keeps depending on
  `flutter_patcher: 1.1.0`. The plugin is part of the host, so a patch made
  after upgrading the dependency fails with `PATCH_NATIVE_CHANGE`.

## 1.1.0

1.1.0 makes a patch one file. `patch` writes one file per host, the app gets
it in any way it likes and hands it to the plugin, and the plugin verifies it
and installs it for the next cold start. `build` and `patch` are all a
self-hosted delivery needs. Hosts shipped with 1.0.0 are not affected; see
"Upgrading from 1.0" below.

### A patch is one `.fptc` file

**Changed** · CLI · 2026-11-10 · flutter_patcher 1.1.0

`patch` writes one file per host, such as `1-arm64-v8a.fptc`, and reports its
full path as `file`, with `seq` and `signed`.

- Before: `patch` wrote an unsigned patch, and `publish` turned it into a
  signed manifest with objects that devices fetched from `url`.
- Now: a patch file (FPTC v1) is a 146-byte header (magic, version, host
  fingerprint, sequence, payload length, payload SHA-256, Ed25519 signature or
  zeros) followed by the patch ZIP. A device installs a file only when it is
  for this exact host, intact, signed by the host's key when the host has one,
  and numbered above every file it accepted; it checks the installed patch
  again at every cold start. Files are named `<version_code>-<abi>.fptc` for
  the default flavor and channel, and
  `<version_code>-<flavor>-<channel>-<abi>.fptc` otherwise, such as
  `3-paid-beta-arm64-v8a.fptc`; flavors and channels contain only letters,
  digits and `_`, and `build` refuses other characters. On a signed host whose
  private key this machine lacks, `file` is `null`: run `keys import` and
  patch again, or let `publish` seal the output.
- To keep the previous behavior: none on 1.1. Hosts built with 1.0.0 keep the
  manifest protocol with flutter_patcher 1.0.0+1.

Docs: [Patch files](doc/cli.md#patch-files)

### Signing is optional

**Changed** · CLI · 2026-11-10 · flutter_patcher 1.1.0

`build` needs no keys.

- Before: `build` required the keys `keys init` created.
- Now: unless `trust.enabled` in `flutter_patcher.yaml` is `true`, `build`
  makes an unsigned host and prints `WARNING: UNSIGNED`. An unsigned host installs any
  file of its own build, so whoever can hand the app a file can run code in
  it; the built-in downloader accepts only HTTPS, or plain HTTP to the device
  itself. A host keeps the mode it was built with.
- To keep the previous behavior: set `trust.enabled: true` before the build
  you ship.

Docs: [3. Turn On Signing](doc/production-playbook.md#3-turn-on-signing)

### One key signs patch files

**Changed** · CLI · 2026-11-10 · flutter_patcher 1.1.0

The patch key is the only key.

- Before: a project had root, publisher and patch keys, and the root key
  could replace the publisher key without a new release.
- Now: `init` creates the patch key, and `keys export`, `import` and
  `status` handle it only. `trust` in `flutter_patcher.yaml` is read only for `patch`; the `root`
  and `publisher` entries 1.0 wrote are ignored. 1.0 key bundles and key-store
  directories still work, and only their patch key is used. `signing.command`
  always signs with `FLUTTER_PATCHER_SIGN_ROLE=patch`. Installing a malicious
  patch on a signed host now takes only the patch private key; in 1.0 it took
  the patch and publisher keys, which lived in one key bundle. There is no key
  rotation: when the patch key is lost or leaks, the hosts built with it need
  a new release.

Docs: [keys](doc/cli.md#keys)

### `publish` is optional and numbers files at publish time

**Changed** · CLI · 2026-11-10 · flutter_patcher 1.1.0

`publish` seals a patch output again with a sequence numbered at publish time
and writes `<fileName>` at the root of the store.

- Before: `publish` read the release's manifest at `url`, numbered patches
  1, 2, 3, signed the patch and committed a manifest; an interrupted publish
  resumed on the next run.
- Now: the store is `file://` (by default `.flutter_patcher/updates`) or
  `s3://`. `publish` replaces the file there only with a higher sequence
  (`PUBLISH_SEQUENCE_CONFLICT` otherwise), reports `already_published` for
  the same patch, fails with `PUBLISH_CONFLICT` when the file changed while
  publishing, and only previews without `--yes` when not interactive. A signed
  host without a private key fails with `KEYS_NOT_FOUND` before anything is
  written. `--seq <n>` sets the sequence; the default is the current Unix
  time in seconds. `publish` no longer reads `url`.

Docs: [publish](doc/cli.md#publish)

### `serve` offers the files `patch` wrote and publishes nothing

**Changed** · CLI · 2026-11-10 · flutter_patcher 1.1.0

`serve` is a development aid only.

- Before: `serve` published each new patch and served it to a USB-connected
  Android device.
- Now: on `127.0.0.1:8686`, through `adb reverse` on USB Android devices, it
  serves the newest file `patch` wrote for each host, a patch or a
  withdrawal, exactly as written, and picks up each new `patch` run within
  about 2 seconds. It answers `Range` requests, as `checkUpdate` sends. It
  writes no store, numbers nothing and signs nothing, and works whatever
  `store` names. When a host's newest output has no file, it says so and
  serves nothing for that host; run `keys import` and patch again.

Docs: [serve](doc/cli.md#serve)

### `checkUpdate` reads the first 146 bytes of one file

**Changed** · Runtime · 2026-11-10 · flutter_patcher 1.1.0

`checkUpdate()` sends one `Range` request for `<url>/<fileName>`.

- Before: the plugin fetched and verified a signed manifest.
- Now: no file at that address (`404`) means no update. Without a `url`
  given or built in, `checkUpdate` throws `PatcherException`. `checkUpdate`
  and `applyPatch` remain as an optional downloader; the plugin fetches
  nothing else by itself.

Docs: [`checkUpdate`](doc/api-reference.md#checkupdate)

### Patch versions are Unix seconds

**Changed** · Runtime · 2026-11-10 · flutter_patcher 1.1.0

A file is numbered with the time it was sealed.

- Before: `currentVersion`, `PatchInfo.version`,
  `PatchBootDiagnostic.patchVersion` and the sequence in
  `BlacklistEntry.version` showed 1, 2, 3.
- Now: they show Unix seconds, so an app that displays them shows the new
  numbers.

Docs: [`currentVersion`](doc/api-reference.md#currentversion)

### `init` sets up a project, and `trust.enabled` turns signing on

**Changed** · CLI · 2026-11-10 · flutter_patcher 1.1.0

`dart run flutter_patcher init` prepares a project once: it creates
`flutter_patcher.yaml` with every setting commented out, creates the patch key
with `trust.enabled: false`, and warns about what `build` would refuse.

- Before: `keys init` created the patch key and the file, and hosts built
  from then on were signed.
- Now: `init` replaces `keys init`, which fails with `USAGE_ERROR` and names
  `init`. Signing starts only once you set `trust.enabled: true`. Run again,
  `init` keeps the existing file and key.
- To keep the previous behavior: a `flutter_patcher.yaml` that names a key
  without `trust.enabled`, as 1.0 wrote it, stays signed.

Docs: [init](doc/cli.md#init)

### The app can install a patch file it obtained itself

**Added** · Runtime · 2026-11-10 · flutter_patcher 1.1.0

- `FlutterPatcher.applyPatchBytes(bytes)` and `applyPatchFile(path)` install
  a patch file, or apply a withdrawal, that the app got in any way.
- `FlutterPatcher.patchTarget` gives the file name this host installs, its
  version code, flavor, channel, ABI, strategy and fingerprint, whether it is
  signed, and the highest sequence it accepted, for an app whose server picks
  the file.
- `FlutterPatcher.inspectPatch(header)` tells from a file's first 146 bytes
  whether it is new to this host.

Docs: [Custom delivery](doc/advanced.md#custom-delivery-from-your-own-server)

### A withdrawal file returns devices to the installed version

**Added** · CLI · 2026-11-10 · flutter_patcher 1.1.0

`patch android|ios --withdraw` writes a withdrawal file of the host under the
same name as its patch file: devices that apply it drop their patch and run
the installed version. It needs only the baseline; nothing is compiled.
`publish --withdraw` writes a withdrawal file to the store, and so does
publishing an output of `patch --withdraw`.

Docs: [Delivering a rollback](doc/production-playbook.md#delivering-a-rollback)

### The signed-manifest Dart API is removed

**Changed** · Runtime · 2026-11-10 · flutter_patcher 1.1.0

This is a breaking change, made on purpose in a minor release: the
signed-manifest protocol is gone, and nothing maps onto it.

- Before: `SignedManifest`, `SignedUpdateResult`,
  `FlutterPatcher.fetchSignedManifest`, `applySignedManifest` and
  `updatePublicationTrust` existed.
- Now: code that uses them fails to compile. Use `applyPatchBytes` or
  `applyPatchFile` with a patch file, or `checkUpdate` and `applyPatch`.

Docs: [Upgrading from 1.0](doc/upgrading.md)

### The `trust` commands, the publish cleanup and their error codes are removed

**Changed** · CLI · 2026-11-10 · flutter_patcher 1.1.0

This is a breaking change for scripts that used them.

- Before: `trust sign`, `trust publish`, `publish --production --request`,
  `keys import --rotate`, `keys init --role` and `keys export --without-root`
  existed.
- Now: the CLI reports an unknown command or option (`USAGE_ERROR`). To clean
  up a store, delete its files directly. These error codes are no longer
  printed: `PUBLISH_BUSY`, `PUBLISH_CATALOG_FULL`, `PUBLISH_CATALOG_INVALID`,
  `PUBLISH_COMMIT_UNKNOWN`, `PUBLISH_DELETE_UNKNOWN`,
  `PUBLISH_MANIFEST_CONFLICT`, `PUBLISH_OBJECT_CHANGED`,
  `PUBLISH_PATCH_INVALID`, `PUBLISH_RETENTION_STALE`,
  `PUBLISH_TARGET_MISMATCH`, `PUBLISH_UPLOAD_FAILED`, `PUBLISH_URL_INVALID`,
  `PUBLISH_URL_UNREACHABLE` and every `TRUST_*` code.
- To keep the previous behavior: use flutter_patcher 1.0.0+1 for hosts built
  with 1.0.0.

Docs: [Removed in 1.1](doc/cli.md#removed-in-11)

### `build` prints a short summary

**Changed** · CLI · 2026-11-10 · flutter_patcher 1.1.0

- Before: `build` printed the full report.
- Now: it prints `app` (the APK or IPA to install), `application_id`,
  `version_code`, `strategy`, `signed`, `fingerprint` and `report`, the path
  of the full report, `build.json`, beside the app.

Docs: [build](doc/cli.md#build)

### Other changes in 1.1.0

**Changed** · CLI · 2026-11-10 · flutter_patcher 1.1.0

- The host policy is schema 2: `application_id`, `version_code`, `flavor`,
  `channel`, `abi`, `strategy` and `fptc_key` (the patch public key, or `-`
  for an unsigned host).
- The Android plugin declares the internet permission, which release builds
  of a new Flutter app lack; the app no longer adds it for `checkUpdate`.
- `build` and `doctor --project` no longer warn about Dart sources with CRLF
  line endings (`CRLF_DART_SOURCES`). Line endings matter only when a patch is
  made from a checkout with other line endings than the host's; then
  `PATCH_NATIVE_CHANGE` says that the native files differ only in line
  endings and names them.
- `build` no longer warns `URL_LOCAL` when `flutter_patcher.yaml` has no
  `url`, because an app can pass its address as `checkUpdate(url: …)`. `url`
  stays optional, as the default address of `checkUpdate()`.
- On its first start as a 1.1 host, a device deletes the signed-manifest
  state 1.0 kept (`noBackupFilesDir/flutter_patcher_auth/` on Android,
  `auth/` in the plugin's directory on iOS).

Docs: [Troubleshooting](doc/troubleshooting.md#every-file-shows-as-changed)

### Upgrading from 1.0

- Hosts shipped with 1.0.0 stay on 1.0.0+1 for their patches: make, publish
  and withdraw their patches with flutter_patcher 1.0.0+1. On 1.1, `patch` for
  a 1.0 baseline fails with `PATCH_BASELINE_INCOMPATIBLE`.
- The project keeps working: commands, `flutter_patcher.yaml` and the key
  store need no change. The next `build` makes a 1.1 host, signed with the
  existing patch key.
- The 1.0 files in the store (`manifests/`, `objects/`, `catalog.json`) are
  neither read nor written by 1.1 and keep serving 1.0 hosts; 1.1 files sit
  beside them at the store root. A 1.0 publish left unfinished
  (`.dart_tool/flutter_patcher/publish-pending.json`) is ignored by 1.1;
  finish it with 1.0.0+1.
- Replace calls to the removed APIs: `applyPatchBytes` or `applyPatchFile` for
  files the app fetches itself, `checkUpdate` and `applyPatch` for files at a
  URL.

Docs: [Upgrading from 1.0](doc/upgrading.md)

## 1.0.0+1

### Fixed

- The 1.0.0 package on pub.dev left out `lib/src/cli/build/`, so the
  command-line tool could not run and pub.dev's analysis failed. 1.0.0+1
  publishes every source file. Nothing else changes; use 1.0.0+1 instead of
  1.0.0, which is retracted.

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
    keys in the user's key store, the public keys in `flutter_patcher.yaml`.
    `keys export`, `keys import` and `keys status` move and inspect them;
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
2. Run `dart run flutter_patcher keys init` and back up the private keys with
   `keys export --out <file>`.
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
