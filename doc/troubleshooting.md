
<!-- ========================================== -->
<!-- doc/troubleshooting.md (English)           -->
<!-- ========================================== -->

# Troubleshooting & Error Codes

**English** | [简体中文](troubleshooting-zh.md)

When a CLI command fails, it prints an error `code` and a descriptive `message` on standard error: `build`, `patch` and `baseline` as one line of JSON, the other commands as `CODE: message`. For example:

```json
{"command":"patch","status":"failed","code":"PATCH_NATIVE_CHANGE","message":"Native plugin/build hook changed: camera"}
```

The `message` field usually points directly to the root cause. This guide covers the most common problems first, followed by every error code flutter_patcher 1.1 can raise, by category, and the codes only flutter_patcher 1.0 raises. For the device side, see the end of this document.

## Common Issues

### Changed a single line of Dart, but every file shows as modified (or fails with `PATCH_NATIVE_CHANGE`)

**Cause**: Source files are compared byte-for-byte against the baseline. On Windows, Git converts line endings to `CRLF` by default. If your baseline was built with `LF` line endings (e.g., on Linux CI) and you run `patch` on a checkout with `CRLF` line endings, every file—including native source files—appears modified. (`build` and `doctor --project` emit warnings when `CRLF` is detected.)

**Fix**: Add `* text=auto eol=lf` to `.gitattributes` in your repository root, re-checkout the working tree, and ensure both `build` and `patch` operate on consistent line endings.

### `BASELINE_NOT_FOUND`: Baseline snapshot missing

`patch` looks up the baseline using the target `flavor` and build number (taken from the `+` suffix in `pubspec.yaml` by default). Check the following:

- Did you accidentally bump the build number in `pubspec.yaml` while fixing the bug? Revert it to match the live release, or pass `--version-code` explicitly.
- Does `--flavor` match the flavor used during `build`?
- Is `baseline_store` on this machine pointing to the same storage backend used during `build`?

### `BASELINE_RELEASE_CONFLICT`: Rebuild rejected

A baseline snapshot with different content already exists for this version number, so `build` refuses to overwrite it.
- If that release is **already live**, increment the build number in `pubspec.yaml` before building.
- If that build was **never shipped** and you want to discard it, delete the corresponding `release-<flavor>-<version_code>-<abi>` object from your baseline store and re-run `build`.

### `PATCH_BASELINE_INCOMPATIBLE`: The host cannot be patched by this flutter_patcher

The `message` says which case it is:

- **Built with flutter_patcher 1.0** (`This host was built with flutter_patcher 1.0`): patch, publish and withdraw for that host with flutter_patcher 1.0.0+1. Hosts built with 1.1 from then on are patched with 1.1.
- **Flutter version differs**: patches must be generated with the **exact same Flutter SDK version** that built the release. Switch to it, or point to it with `--flutter-sdk`.
- **Baseline lacks records** (`rebuild host`): the host predates what this version needs; build and ship a new host.
- **From `publish`** (`is not a patch output of this flutter_patcher`): the `--patch` directory was written by flutter_patcher 1.0; run `patch` again.

### `BASELINE_STORE_UNREACHABLE` even though storage is accessible

When querying an object that does not exist, your storage backend must return `404` (`NoSuchKey` on S3). On AWS S3 and compatible services, IAM roles without `s3:ListBucket` permission return `403 Forbidden` for missing objects (some CDNs behave similarly), which triggers this error. Grant `s3:ListBucket` to the role—the error `message` will name the specific object that failed.

### `PUBLISH_SEQUENCE_CONFLICT`: The store holds a newer file

The store's file for this host has a `seq` not below the one `publish` would write. A file's `seq` is the Unix time it was sealed, so this means a computer with a clock ahead of yours published last, or a `--seq` was given before. Fix this computer's clock, or publish with the `--seq` the `message` suggests. Devices that took the newer file accept only files numbered above it.

### `patch` succeeds with `"file":null`

The host was built with a patch key (`trust.patch`) and no source on this machine holds its private key. The draft is in the output directory. Run `publish --patch <output>` on a machine that has the key, or bring the key here with `keys import <bundle>` and run `publish`. `keys status` shows where the key would come from.

### `HOST_UNSUPPORTED`: Unsupported host OS or architecture

- **Building Android baselines (`build android`)**: Requires Linux x64, Windows x64 or an Apple Silicon Mac.
- **Building iOS baselines (`build ios`)**: Requires an Apple Silicon Mac.
- **Generating patches (`patch android` / `patch ios`)**: Supported on all three host platforms above.

### `checkUpdate` on the device never finds an update

- `checkUpdate` requests `<url>/<fileName>`: compare `FlutterPatcher.patchTarget.fileName` with the file in your store, and `url` with where it is served. Without `url` in the call, it is `url` from `flutter_patcher.yaml` when the app was built (rebuild after changing it).
- A `file://` store with `url` set is not what devices read: upload the file to `<url>/<fileName>` after each `publish`.
- The file must be newer than `patchTarget.acceptedSeq`. A file sealed on a computer whose clock is behind, or an old file uploaded again, is not; `publish` it again (with `--seq` above `acceptedSeq` if needed).
- The file must be for the build installed on the device (`patchTarget.versionCode`, `flavor`, `channel`, `abi`, `fingerprint`). After users update the app from the store, make and publish a patch for the new build.
- A CDN may still serve the previous file; shorten its cache lifetime for `.fptc` files.
- The endpoint must answer directly over HTTPS, without `3xx` redirects, and `404` for a missing file.
- To see what the device thinks of the file, fetch its first 146 bytes yourself and pass them to `FlutterPatcher.inspectPatch`: `reason` says why it is not new.

---

## CLI Error Codes

### 1. Environment & Toolchain

| Error Code | Meaning | Resolution |
|---|---|---|
| `FLUTTER_NOT_FOUND` | `flutter` is not available in `PATH` | Add Flutter to `PATH` or specify `--flutter-sdk` |
| `FLUTTER_VERSION_INVALID` | Failed to parse Flutter version info | Run `flutter --version` to verify the SDK installation |
| `SDK_NOT_READY` | The selected Flutter SDK is uninitialized or has an incomplete cache | Run `flutter doctor` once, then retry |
| `SDK_PREPARE_FAILED` | Failed to prepare the internal Flutter SDK workspace | Check network connectivity and disk space, then retry; open an issue if it persists |
| `ENGINE_ARTIFACT_MISSING` | No prebuilt engine artifacts available for this Flutter version | Switch to a supported Flutter version; see the [README](../README.md) |
| `ENGINE_ARTIFACT_MISMATCH`<br>`ARTIFACT_HASH_MISMATCH`<br>`ARTIFACT_INVALID`<br>`ENGINE_MANIFEST_INVALID`<br>`TOOLS_ARTIFACT_MISSING`<br>`TOOLS_VERSION_UNSUPPORTED`<br>`YAML_CACHE_INVALID`<br>`YAML_GENERATION_FAILED`<br>`EMBEDDING_POM_UNAVAILABLE` | Downloaded engine or toolchain artifacts are incomplete or failed checksum verification | Check your network connection and retry; corrupted cache entries are automatically quarantined and re-downloaded |
| `CACHE_INVALID` | A path the command uses (cache, project, store, keys, patch output or receipt) is or passes through a symbolic link | Use the real path instead of a symbolic link |
| `HOST_UNSUPPORTED` | Current OS or CPU architecture is unsupported for this command | See [`HOST_UNSUPPORTED` above](#host_unsupported-unsupported-host-os-or-architecture) |
| `ANDROID_SDK_MISSING` | Android SDK or `build-tools` not found | Set `ANDROID_HOME` or run `flutter config --android-sdk` |
| `JAVA_HOME_INVALID` | `JAVA_HOME` does not point to a valid JDK | Fix your `JAVA_HOME` environment variable |
| `XCODE_MISSING` | Xcode or the iOS platform SDK is not installed | Install Xcode and download the iOS platform component in Xcode Settings |
| `DISK_FULL` | Insufficient disk space | Free up disk space and retry |
| `PUB_LOCKFILE_MISMATCH` | `pubspec.lock` does not match `pubspec.yaml`, or was resolved with another package host (for example, a `PUB_HOSTED_URL` mirror set in one terminal and not in another) | Run `flutter pub get` in the project from the terminal you build in, then retry |
| `TOOL_FAILED` | An underlying build tool exited with an error | Inspect the tail of the tool's output included in `message` |
| `CONFIG_INVALID` | Invalid `flutter_patcher.yaml` (an unknown setting, a value of the wrong shape, a `trust` without a valid `patch` key), an invalid CLI flag, or `HOME`/`USERPROFILE` not set | Fix the configuration or flag as described in `message` |
| `USAGE_ERROR` | Incorrect CLI command syntax, including commands and options removed in 1.1 (`trust`, `publish --production`/`--request`, `keys import --rotate`, `keys init --role root\|publisher`) | Run with `--help` to see valid usage; see [CLI Reference: Removed in 1.1](cli.md#removed-in-11) |
| `DOCTOR_FAILED` | `doctor` encountered an unexpected error | Check `message` for details |
| `INTERFACE_INPUT_MISSING`<br>`INTERFACE_GENERATION_FAILED`<br>`INTERFACE_INDEX_FAILED`<br>`INTERFACE_VALIDATION_FAILED`<br>`INTERFACE_NOT_CONVERGED`<br>`INTERFACE_NO_PROGRESS` | The maintainer command `interface` could not generate or validate a host interface | Only maintainers adapting a new Flutter version run it; check `message` |

### 2. Keys and Signing (`keys`, `patch`, `publish`, `serve`)

| Error Code | Meaning | Resolution |
|---|---|---|
| `KEYS_NOT_CONFIGURED` | `keys export` in a project whose `flutter_patcher.yaml` has no `trust.patch` | Run `keys init`, or `keys import` the project's key bundle |
| `KEYS_NOT_FOUND` | A signed host's file must be signed and no source holds the private key (`publish`, `serve`); the `--key-file` or `keys import` file does not exist; or `keys export` finds no key in this machine's key store | Run `keys import <file>`, set `FLUTTER_PATCHER_KEYS`, or configure `signing.command`; `keys status` shows what this machine has |
| `KEYS_MISMATCH` | The first key source holds a key other than the host's `trust.patch`, `keys import` got another key than `flutter_patcher.yaml` names, or a stored key's signature does not verify | Use the project's key. A host accepts only the key it was built with; a new key needs new hosts |
| `KEYS_ALREADY_CONFIGURED` | `keys init` in a project that already names a patch key, or still has a `flutter_patcher_keys/` directory | Bring the existing key to this machine with `keys import <bundle>`, or `keys import flutter_patcher_keys` for the old directory |
| `KEYS_BUNDLE_INVALID` | The file is not a key bundle, holds no patch key, or the directory has no `patch/private-key.base64`; also a damaged file in `~/.flutter_patcher/keys/` (named in `message`) | Use a file written by `keys export`, or a 1.0 bundle that has a patch key |
| `SIGNER_COMMAND_FAILED` | `signing.command` could not start, exited non-zero, took over 60 seconds, printed no base64 64-byte signature, or signed with another key | Run the command by hand with the same environment; check that the service's key is pure Ed25519 and is the patch key |
| `PATCH_SIGN_FAILED` | A signature failed its self-check while sealing | Check where the patch key comes from with `keys status` |
| `KEYS_OUTPUT_EXISTS`<br>`KEYS_OUTPUT_UNAVAILABLE` | The output file already exists, or the key store directory cannot be created | Choose a new file; check the permissions of `~/.flutter_patcher/keys` |
| `KEYS_PERMISSIONS_FAILED` | Failed to restrict file permissions on private keys | Verify that the filesystem supports standard permission attributes |
| `KEYS_IO_ERROR` | Failed to read or write keys | Check directory permissions and retry |

### 3. Building Baselines (`build`)

| Error Code | Meaning | Resolution |
|---|---|---|
| `BUILD_CONFIG_INVALID` | Invalid build configuration: no `+` build number in `pubspec.yaml`, no single application id, an invalid `--host-policy` file (neither schema 2 nor a 1.0 schema 1 policy), `--flavor` or `--version-code` differing from that policy, or an output directory that exists | Supply or fix what `message` names (e.g., `version: 1.0.0+1`, `--application-id`, a new `--out`) |
| `BUILD_PROJECT_INVALID` | Unsupported project layout (e.g., symlinks in source packages, or directory names colliding with `build` case-insensitively) | Adjust the project structure as indicated in `message` |
| `BUILD_BOOTSTRAP_UNAVAILABLE` | Project does not depend on `flutter_patcher` | Run `flutter pub add flutter_patcher` |
| `BUILD_INPUT_CHANGED` | Source files were modified while the build was running | Do not edit files during `build`; re-run the command |
| `BUILD_STEP_FAILED` | Underlying Flutter build step failed | Check the log tail and log directory path reported in `message` |
| `BUILD_APK_INVALID`<br>`BUILD_IPA_INVALID`<br>`ENGINE_INJECTION_FAILED` | Produced app bundle failed validation or engine injection | On iOS, verify code signing and `--export-method`; otherwise, open an issue |
| `BASELINE_RELEASE_CONFLICT` | A different baseline already exists for this build number | See [`BASELINE_RELEASE_CONFLICT` above](#baseline_release_conflict-rebuild-rejected) |
| `BASELINE_CONTENT_CONFLICT` | Identical source inputs produced conflicting build outputs | Please open an issue |
| `BUILD_FAILED` | Unexpected build failure | Check `message` for details |

### 4. Baseline Storage

| Error Code | Meaning | Resolution |
|---|---|---|
| `BASELINE_NOT_FOUND` | Baseline snapshot not found for this release | See [`BASELINE_NOT_FOUND` above](#baseline_not_found-baseline-snapshot-missing) |
| `BASELINE_STORE_UNREACHABLE` | Cannot reach or authenticate with baseline storage | Check network, credentials, and `s3:ListBucket` permissions (see above) |
| `BASELINE_STORE_PROTOCOL` | Storage backend does not support conditional create-if-not-exists writes | See [CLI Reference: Storage requirements](cli.md#storage-requirements) |
| `BASELINE_INVALID` | Baseline snapshot is corrupted | Restore the baseline object from backup |
| `BASELINE_FINGERPRINT_MISMATCH` | Baseline fingerprint does not match the requested release parameters | Verify `--version-code`, `--flavor`, and Flutter SDK version |
| `BASELINE_ARTIFACTS_MISSING`<br>`BASELINE_SCHEMA_UNSUPPORTED`<br>`BASELINE_NOT_RELEASE` | Baseline was created by an incompatible older version of `flutter_patcher` | Rebuild and ship a new baseline release using the current `flutter_patcher` version |
| `BASELINE_RELEASE_AMBIGUOUS` | An old-format record and a current release object for the same version disagree | Delete the one named in `message` |
| `BASELINE_OPERATION_FAILED` | Unexpected baseline storage error | Check `message` for details |

### 5. Generating Patches (`patch`)

**Safety Check Rejections** (blocks unsupported changes from being packaged into a patch):

| Error Code | Meaning | Resolution |
|---|---|---|
| `PATCH_NATIVE_CHANGE` | Native code, native plugins, or build hooks were modified, or a new native dependency was added. A different flutter_patcher version than the host was built with counts too | Revert the native changes or ship a full app release; patch with the flutter_patcher version the host was built with. (If you didn't touch native code, check for `CRLF` line-ending diffs above.) |
| `PATCH_PINNED_PACKAGE_CHANGED` | A package locked to the baseline (because it contains or is depended on by native code) changed version | Pin the package back to its baseline version under `dependency_overrides` as shown in `message` |
| `PATCH_FFI_UNSUPPORTED` | Modified Dart code invokes native functions via `dart:ffi` | Keep FFI calls inside unmodified baseline code, or ship a full app release |
| `PATCH_UNSAFE` | Bytecode compatibility verification failed | Check `message` for the specific violations and inspect the working directory logs |
| `PATCH_DYNAMIC_ICON` | Code dynamically constructs non-`const` `IconData` at runtime | Replace with compile-time constant icons (`const IconData(...)` or `Icons.*`) |
| `PATCH_ASSET_DELETE_UNSUPPORTED` | An existing bundled asset was deleted | Restore the asset file, or ship a full app release |
| `PATCH_ENGINE_UNSUPPORTED` | The baseline app's engine does not support asset patching | Rebuild and ship a new baseline release with the current version |
| `PATCH_NO_CHANGES` | No effective changes detected against the baseline | Make sure your edits are saved and you are diffing against the intended baseline version |

**Patch Warnings** (patch generation succeeds, but review potential runtime behavior):

| Warning Code | Meaning |
|---|---|
| `PATCH_NATIVE_ASSET_READER` | Native code reads an asset that was modified in this patch; native code will continue to see the original asset bundled in the baseline app |
| `PATCH_BACKGROUND_ENTRY` | An entry-point function runs on a separate Flutter engine (e.g., background isolate tasks) and may continue executing baseline code or assets |
| `PATCH_RESOURCE_SIZE` | Patched assets exceed 16 MB in total and will remain resident in memory for the lifetime of the app process |

**Other `patch` Errors**:

| Error Code | Meaning | Resolution |
|---|---|---|
| `PATCH_BASELINE_INCOMPATIBLE` | The host was built with flutter_patcher 1.0, with another Flutter version, or lacks records this version needs; from `publish`, a patch output of flutter_patcher 1.0 | See `PATCH_BASELINE_INCOMPATIBLE` under Common Issues above |
| `PATCH_TARGET_MISMATCH` | Entry-point target file differs from the baseline build | Pass the same `--target` used during `build` |
| `PATCH_DRAFT_INVALID` | `patch` or `publish` found no valid `patch.draft` in the output directory | Pass an output of `patch` from this flutter_patcher version, or run `patch` again |
| `PATCH_CONFIG_INVALID` | Invalid options, such as the flavor, build number or `--target`, or an output directory that already exists | Fix them as described in `message` |
| `PATCH_COMPILE_FAILED` | Dart compilation failed | Verify that a standard `flutter build` succeeds first |
| `PATCH_SOURCE_INVALID`<br>`PACKAGE_INPUT_INVALID` | Unsupported source package layout (e.g., contains symlinks) | Remove symlinks or adjust layout as described in `message` |
| `PATCH_ASSET_INVALID`<br>`FONT_SUBSET_FAILED` | Asset processing or icon font tree-shaking failed | Fix the offending asset or font file as indicated in `message` |
| `PATCH_TOOL_FAILED` | Internal compilation or diff tool failed | Inspect the tool output and working directory in `message` |
| `PATCH_PACKAGE_INVALID` | Failed to package the patch | Please open an issue |
| `PATCH_FAILED` | Unexpected patch generation failure | Check `message` for details |

### 6. Publishing & Local Serving (`publish`, `serve`)

| Error Code | Meaning | Resolution |
|---|---|---|
| `PUBLISH_CONFIG_INVALID` | No patch output to publish (none under `.dart_tool/flutter_patcher/patches/` and no `--patch`), unexpected arguments, a `--receipt` file that already exists, or a `store` URI with credentials, a query or a fragment | Run `patch` first or pass `--patch`; choose a new receipt file; fix `store` |
| `PUBLISH_SEQUENCE_CONFLICT` | The store's file for this host has a `seq` not below the new one, or `--seq` is not a number from 1 to 4294967295 | See `PUBLISH_SEQUENCE_CONFLICT` under Common Issues above |
| `PUBLISH_CONFLICT` | The store's file changed between `publish` reading and writing it, for example another `publish` at the same time | Run `publish` again |
| `PUBLISH_STORE_UNAVAILABLE` | The AWS CLI is missing or failed, the store does not support conditional writes, or the role lacks `s3:ListBucket` (a missing file then reads as access denied) | Check the AWS CLI version, credentials, permissions and `FLUTTER_PATCHER_S3_ENDPOINT` |
| `PUBLISH_STORE_INVALID` | Invalid `s3://` store (an S3 prefix must be below the bucket root and use only letters, digits, `_` and `-`), a stored file over 320 MiB, or an S3 response without an ETag | Fix the `store` setting as described in `message`; replace the oversized file |
| `PUBLISH_FAILED` | Unexpected publication failure, including a store file of this host's name that is not an FPTC v1 file | Delete or replace that file in the store; otherwise check the store and `message` |
| `SERVE_CONFIG_INVALID` | `serve` only supports a `file://` publication store | Remove the remote `store` setting from `flutter_patcher.yaml` during local development |
| `SERVE_PORT_BUSY` | Another program listens on the port `serve` uses | Stop it, or run `serve --port <port>` and map the phone's `8686` to it with `adb reverse tcp:8686 tcp:<port>` |

`serve` does not stop when publishing an output fails: it prints `Not offered: <code>: <message>` with one of the codes above, and keeps serving what the store holds.

### 7. Warnings

These print as `WARNING: <code>: <text>` and do not fail the command:

| Warning Code | Meaning |
|---|---|
| `UNSIGNED` | `build` made a host without a patch key: it accepts unsigned files, so whoever can hand the app a file can run code in it. To sign, run `keys init` and build again |
| `URL_LOCAL` | `flutter_patcher.yaml` has no `url`, so `checkUpdate()` without `url` checks `serve`'s local address. Set `url` before building a release for the store, unless the app obtains patch files itself |
| `BASELINE_STORE_LOCAL` | `build` keeps the baseline only inside the project, in `.flutter_patcher/`. Back that folder up, or set `baseline_store`; every patch of the host needs it |
| `CRLF_DART_SOURCES` | `build` found Dart sources with `CRLF` line endings; patches must be built from a checkout with the same line endings (see above) |
| `ARTIFACT_CHECK_SKIPPED` | The artifact index could not be downloaded, so the cached index was used |

---

## flutter_patcher 1.0 only

flutter_patcher 1.1 never raises these codes. They come from flutter_patcher 1.0.0+1 working on hosts built with 1.0.0, which use signed manifests, `catalog.json` and trust updates. Keep using 1.0.0+1 for those hosts; 1.1 does not read or change what 1.0 keeps in the store (`manifests/`, `objects/`, `catalog.json`) or in `.dart_tool/flutter_patcher/publish-pending.json`.

| Error Code | Meaning | Resolution (with 1.0.0+1) |
|---|---|---|
| `PUBLISH_BUSY`<br>`PUBLISH_COMMIT_UNKNOWN`<br>`PUBLISH_UPLOAD_FAILED`<br>`PUBLISH_DELETE_UNKNOWN` | A previous 1.0 publication or cleanup was interrupted | Run `publish` (or the same request file) again in the same project with 1.0.0+1; it resumes from `publish-pending.json`. Do not delete files from the store |
| `PUBLISH_URL_UNREACHABLE`<br>`PUBLISH_URL_INVALID` | 1.0 `publish` could not read the release's manifest at `url`, or found something else there | Fix `url` or the network; the address must answer `404` for a release with nothing published |
| `PUBLISH_CATALOG_INVALID`<br>`PUBLISH_CATALOG_FULL` | `catalog.json` is damaged, belongs to another application id, or reached 8 MiB | Use a dedicated store path per app; never edit the store by hand; open an issue for a full catalog |
| `PUBLISH_MANIFEST_CONFLICT` | `manifests/<hash>.json` kept changing while 1.0 rewrote it | Run `publish` again |
| `PUBLISH_RETENTION_STALE`<br>`PUBLISH_OBJECT_CHANGED` | A 1.0 cleanup plan is stale | Run the dry run again for a fresh plan |
| `PUBLISH_TARGET_MISMATCH` | The patch does not belong to the release | Make the patch again for that release |
| `PUBLISH_PATCH_INVALID` | The patch bundle is damaged or over 320 MB | Make the patch again; reduce its assets |
| `PUBLISH_SIGNATURE_INVALID` | A signature did not verify against the baseline's patch key or `--root-public` | Publish with the keys the host was built with |
| `TRUST_CONFIG_INVALID`<br>`TRUST_INVALID`<br>`TRUST_REPLAY`<br>`TRUST_SCOPE_CONFLICT`<br>`TRUST_CONFLICT`<br>`TRUST_OUTPUT_EXISTS`<br>`TRUST_FAILED` | A 1.0 `trust sign` or `trust publish` failed | Follow `message`; increment `revision` beyond the published one for `TRUST_REPLAY` |

---

## On-Device Debugging

The device does not use the CLI error codes above. To diagnose a device:

1. **Install failures**: `applyPatch`, `applyPatchBytes` and `applyPatchFile` return a `PatchApplyError`; see [API Reference](api-reference.md) for each value and the rules a file must meet. `invalidArgs` means the file is not newer than `patchTarget.acceptedSeq`; `signatureInvalid` means it is not this build's file, is damaged, or is not signed by the host's patch key.
2. **Update not found**: `FlutterPatcher.inspectPatch` on the file's first 146 bytes gives the `reason`; see `checkUpdate` above.
3. **Patch did not activate after cold start**: inspect `FlutterPatcher.lastBootDiagnostic` to see why the runtime skipped or rolled back the patch; see [Crash Protection](crash-protection.md).
4. **Verbose runtime logs**: during development, filter Android `logcat` or the iOS Xcode Console by `FlutterPatcher` to view native verification and loading logs.
