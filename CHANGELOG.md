> Chinese version: [CHANGELOG-zh.md](CHANGELOG-zh.md)

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
- Hot updates only cover Dart AOT code; assets such as
  `flutter_assets` and `isolate_snapshot_data` are not replaced.

### Documentation

- Repository README: use cases, 5-minute demo, integration steps.
- `doc/architecture.md`: native + Dart layered architecture and
  startup sequence.
- `doc/api-reference.md`: full API reference.
- `doc/crash-protection.md`: breaker and rollback strategy.
