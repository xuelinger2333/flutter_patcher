
<!-- ========================================== -->
<!-- doc/troubleshooting.md (English)           -->
<!-- ========================================== -->

# Troubleshooting & Error Codes

**English** | [简体中文](troubleshooting-zh.md)

When a CLI command fails, it prints an error `code` and a descriptive `message` on standard error: `build`, `patch` and `baseline` as one line of JSON, the other commands as `CODE: message`. For example:

```json
{"command":"patch","status":"failed","code":"PATCH_NATIVE_CHANGE","message":"Native plugin/build hook changed: camera"}
```

The `message` field usually points directly to the root cause. This guide covers the most common pitfalls first, followed by a complete reference of CLI error codes by category. For client-side (on-device) debugging, see the end of this document.

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

### `PATCH_BASELINE_INCOMPATIBLE`: Flutter version mismatch

Patches must be generated using the **exact same Flutter SDK version** that built the baseline release. Switch to that Flutter version, or point to it explicitly via `--flutter-sdk`.

### `BASELINE_STORE_UNREACHABLE` even though storage is accessible

When querying an object that does not exist, your storage backend must return `404` (`NoSuchKey` on S3). On AWS S3 and compatible services, IAM roles without `s3:ListBucket` permission return `403 Forbidden` for missing objects (some CDNs behave similarly), which triggers this error. Grant `s3:ListBucket` to the role—the error `message` will name the specific object that failed.

### `PUBLISH_BUSY` or `PUBLISH_COMMIT_UNKNOWN`: Interrupted publication

A previous `publish` operation was interrupted around the commit phase (e.g., network drop or killed process). To prevent state corruption, the publication store locks itself until that exact operation finishes. **Do not manually delete files from storage.** Run `publish` (or `serve`) again in the same project: it resumes the interrupted publication from the request it saved in `.dart_tool/flutter_patcher/publish-pending.json`, and afterwards accepts new work. For a request file (`--production --request`), run the same file again.

### `HOST_UNSUPPORTED`: Unsupported host OS or architecture

- **Building Android baselines (`build android`)**: Requires Linux x64, Windows x64 or an Apple Silicon Mac.
- **Building iOS baselines (`build ios`)**: Requires an Apple Silicon Mac.
- **Generating patches (`patch android` / `patch ios`)**: Supported on all three host platforms above.

### `checkUpdate` on the device never finds an update

- Verify that the URL passed to `checkUpdate` is the **root URL** of your publication store, not a direct link to a file inside `manifests/`.
- Ensure the endpoint serves content directly over HTTPS without `3xx` redirects.
- Confirm the patch was built for the exact `versionCode` installed on the device. If a user updates the app from the store, you must publish a separate patch targeting the new version.
- Check whether the patch is already installed on the device (already-applied patches are not reported as new updates; check `FlutterPatcher.currentVersion`).

---

## CLI Error Codes

### 1. Environment & Toolchain

| Error Code | Meaning | Resolution |
|---|---|---|
| `FLUTTER_NOT_FOUND` | `flutter` is not available in `PATH` | Add Flutter to `PATH` or specify `--flutter-sdk` |
| `FLUTTER_VERSION_INVALID` | Failed to parse Flutter version info | Run `flutter --version` to verify the SDK installation |
| `SDK_NOT_READY` | The selected Flutter SDK is uninitialized or has an incomplete cache | Run `flutter doctor` once, then retry |
| `SDK_PREPARE_FAILED` | Failed to prepare the internal Flutter SDK workspace | Check network connectivity and disk space, then retry; open an issue if it persists |
| `ENGINE_ARTIFACT_MISSING` | No prebuilt engine artifacts available for this Flutter version | Switch to a [supported Flutter version](../README.md#supported-versions--requirements) |
| `ENGINE_ARTIFACT_MISMATCH`<br>`ARTIFACT_HASH_MISMATCH`<br>`ARTIFACT_INVALID`<br>`ENGINE_MANIFEST_INVALID`<br>`TOOLS_ARTIFACT_MISSING`<br>`TOOLS_VERSION_UNSUPPORTED`<br>`YAML_CACHE_INVALID`<br>`YAML_GENERATION_FAILED`<br>`EMBEDDING_POM_UNAVAILABLE` | Downloaded engine or toolchain artifacts are incomplete or failed checksum verification | Check your network connection and retry; corrupted cache entries are automatically quarantined and re-downloaded |
| `CACHE_INVALID` | A path the command uses (cache, project, store, keys, patch output or receipt) is or passes through a symbolic link | Use the real path instead of a symbolic link |
| `HOST_UNSUPPORTED` | Current OS or CPU architecture is unsupported for this command | See [`HOST_UNSUPPORTED` above](#host_unsupported-unsupported-host-os-or-architecture) |
| `ANDROID_SDK_MISSING` | Android SDK or `build-tools` not found | Set `ANDROID_HOME` or run `flutter config --android-sdk` |
| `JAVA_HOME_INVALID` | `JAVA_HOME` does not point to a valid JDK | Fix your `JAVA_HOME` environment variable |
| `XCODE_MISSING` | Xcode or the iOS platform SDK is not installed | Install Xcode and download the iOS platform component in Xcode Settings |
| `DISK_FULL` | Insufficient disk space | Free up disk space and retry |
| `TOOL_FAILED` | An underlying build tool exited with an error | Inspect the tail of the tool's output included in `message` |
| `CONFIG_INVALID` | Invalid `flutter_patcher.yaml` option or CLI flag | Fix the configuration or flag as described in `message` |
| `USAGE_ERROR` | Incorrect CLI command syntax | Run with `--help` to see valid usage |
| `DOCTOR_FAILED` | `doctor` encountered an unexpected error | Check `message` for details |

### 2. Key Management (`keys`)

| Error Code | Meaning | Resolution |
|---|---|---|
| `KEYS_NOT_CONFIGURED` | `flutter_patcher.yaml` has no `trust` keys | Run `keys init` once for the project, or `keys import` its key bundle |
| `KEYS_NOT_FOUND` | No source holds a private key that `publish` or `trust sign` needs | Run `keys import <file>`, set `FLUTTER_PATCHER_KEYS`, or configure `signing.command`; `keys status` shows what this machine has |
| `KEYS_MISMATCH` | A private key is not the one `flutter_patcher.yaml` names, or the release was built with other keys | Use the project's keys. Never create new keys for a project with shipped hosts |
| `KEYS_ALREADY_CONFIGURED` | `keys init` in a project that already has keys | Bring the existing keys to this machine with `keys import` |
| `KEYS_BUNDLE_INVALID` | The file is not a key bundle | Use a file written by `keys export` |
| `SIGNER_COMMAND_FAILED` | `signing.command` failed, timed out or printed no valid signature | Run the command by hand; check that the service's key is Ed25519 |
| `KEYS_OUTPUT_EXISTS`<br>`KEYS_OUTPUT_UNAVAILABLE` | The output file already exists, or the key store directory cannot be created | Choose a new file; check the permissions of `~/.flutter_patcher/keys` |
| `KEYS_PERMISSIONS_FAILED` | Failed to restrict file permissions on private keys | Verify that the filesystem supports standard permission attributes |
| `KEYS_CRYPTO_FAILED`<br>`KEYS_IO_ERROR` | Failed to generate or write keypairs | Check directory permissions and retry |

### 3. Building Baselines (`build`)

| Error Code | Meaning | Resolution |
|---|---|---|
| `BUILD_CONFIG_INVALID` | Invalid build configuration (e.g., missing `+` build number in `pubspec.yaml` or unresolved application ID) | Supply the missing config (e.g., `version: 1.0.0+1` or `--application-id`) |
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
| `PATCH_NATIVE_CHANGE` | Native code, native plugins, or build hooks were modified, or a new native dependency was added | Revert the native changes or ship a full app release. (If you didn't touch native code, check for `CRLF` line-ending diffs above.) |
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
| `PATCH_BASELINE_INCOMPATIBLE` | Flutter version differs from the baseline, or baseline was built with an older incompatible tool | See [`PATCH_BASELINE_INCOMPATIBLE` above](#patch_baseline_incompatible-flutter-version-mismatch) |
| `PATCH_TARGET_MISMATCH` | Entry-point target file differs from the baseline build | Pass the same `--target` used during `build` |
| `PATCH_DRAFT_INVALID` | `publish` got a directory without a valid `patch.draft` | Pass an output of `patch` from this flutter_patcher version |
| `PATCH_CONFIG_INVALID` | Invalid options, such as the sequence, flavor, fingerprint or `--target`, or an output directory that already exists | Fix them as described in `message` |
| `PATCH_COMPILE_FAILED` | Dart compilation failed | Verify that a standard `flutter build` succeeds first |
| `PATCH_SOURCE_INVALID`<br>`PACKAGE_INPUT_INVALID` | Unsupported source package layout (e.g., contains symlinks) | Remove symlinks or adjust layout as described in `message` |
| `PATCH_ASSET_INVALID`<br>`FONT_SUBSET_FAILED` | Asset processing or icon font tree-shaking failed | Fix the offending asset or font file as indicated in `message` |
| `PATCH_TOOL_FAILED` | Internal compilation or diff tool failed | Inspect the tool output and working directory in `message` |
| `PATCH_PACKAGE_INVALID`<br>`PATCH_SIGN_FAILED` | Failed to package or sign the patch bundle | Please open an issue |
| `PATCH_FAILED` | Unexpected patch generation failure | Check `message` for details |

### 6. Publishing & Local Serving (`publish`, `serve`)

| Error Code | Meaning | Resolution |
|---|---|---|
| `PUBLISH_CONFIG_INVALID` | Invalid arguments or request file (e.g., no patch built yet, nothing to withdraw, or `--through` out of bounds) | Run `patch` first, or adjust flags per `message` |
| `PUBLISH_TARGET_MISMATCH` | Patch does not belong to the specified target release | Regenerate the patch for the intended release |
| `PUBLISH_SEQUENCE_CONFLICT`<br>`PUBLISH_CONFLICT` | The patch's sequence does not exceed the latest published or withdrawn sequence, or the store changed concurrently | Run `publish` again without `--seq`, or with a `--seq` above every published or withdrawn sequence; the patch need not be made again |
| `PUBLISH_BUSY`<br>`PUBLISH_COMMIT_UNKNOWN`<br>`PUBLISH_UPLOAD_FAILED`<br>`PUBLISH_DELETE_UNKNOWN` | A prior publication or cleanup operation was interrupted | Run `publish` again in the same project, or the same request file, to resume (see above) |
| `PUBLISH_STORE_UNAVAILABLE` | Cannot access publication storage, or backend lacks conditional write support | Check AWS CLI version, credentials, and `FLUTTER_PATCHER_S3_ENDPOINT` |
| `PUBLISH_STORE_INVALID` | Invalid store URI (an S3 prefix must be below the bucket root and use only letters, digits, `_` and `-`), or an object exceeds the size limits | Fix the `store` setting as described in `message` |
| `PUBLISH_CATALOG_INVALID` | The store's `catalog.json` is damaged or belongs to a different application ID | Use a dedicated storage path per app and never manually edit files inside the store |
| `PUBLISH_MANIFEST_CONFLICT` | `manifests/<hash>.json` kept changing while `publish` rewrote it | Run `publish` again to rewrite it |
| `PUBLISH_CATALOG_FULL` | Publication ledger (`catalog.json`) reached its 8 MiB capacity | Cleanup does not shrink it, and this version cannot archive it; open an issue |
| `PUBLISH_PATCH_INVALID` | Patch bundle is corrupted or exceeds the 320 MB limit | Reduce asset payload size and regenerate the patch |
| `PATCH_SIGN_FAILED` | A patch signature failed its self-check | Check where the patch key comes from with `keys status` |
| `PUBLISH_SIGNATURE_INVALID` | A signature does not verify: the patch against the baseline's `patch` public key (`publish`), or a trust document against `--root-public` (`trust publish`) | Publish with the keys the host was built with, or check the `root` key |
| `PUBLISH_RETENTION_STALE`<br>`PUBLISH_OBJECT_CHANGED` | The approved cleanup plan is stale because storage state changed | Re-run the dry run to generate a fresh cleanup plan |
| `PUBLISH_FAILED` | Unexpected publication failure | Check `message` for details |
| `SERVE_CONFIG_INVALID` | `serve` only supports local `file://` storage | Comment out the remote `store` setting in `flutter_patcher.yaml` during local development |

### 7. Trust Updates (`trust`)

| Error Code | Meaning | Resolution |
|---|---|---|
| `TRUST_CONFIG_INVALID` | Missing required arguments | Supply the missing flags per `message` |
| `TRUST_INVALID` | The trust document's size, fields or canonical form is invalid | Sign it again with `trust sign` instead of editing it |
| `TRUST_REPLAY` | `revision` number was not incremented | Increment `revision` in `fields.json` beyond the currently published revision |
| `TRUST_SCOPE_CONFLICT` | Storage path already holds a trust document for a different baseline scope | Use a dedicated storage path for each baseline scope |
| `TRUST_CONFLICT` | Concurrent modification of the trust store | Fetch the latest state and retry |
| `TRUST_OUTPUT_EXISTS` | Output file already exists locally | Specify a new `--out` filename |
| `TRUST_FAILED` | Unexpected trust operation failure, including a malformed `fields.json` | Verify `fields.json` and key files |

### 8. Other Warnings

These print as `WARNING: <code>: <text>` and do not fail the command:

| Warning Code | Meaning |
|---|---|
| `BASELINE_STORE_LOCAL` | `build` keeps the baseline only inside the project; set `baseline_store` to durable storage (see [Production Playbook](production-playbook.md#configuring-storage)) |
| `CRLF_DART_SOURCES` | `build` found Dart sources with `CRLF` line endings; patches must be built from a checkout with the same line endings (see above) |
| `ARTIFACT_CHECK_SKIPPED` | The artifact index could not be downloaded, so the cached index was used |

---

## On-Device Debugging

The client-side runtime does not use the CLI error codes above. To diagnose issues on a device:

1. **Patch installation failures**: `applyPatch` returns a `PatchApplyError` enum. See [API Reference: `applyPatch`](api-reference.md#applypatch) for the exact meaning of each value.
2. **Patch did not activate after cold start**: Inspect `FlutterPatcher.lastBootDiagnostic` to see why the runtime skipped or rolled back the patch. See [Crash Protection: Boot diagnostics](crash-protection.md#boot-diagnostics).
3. **Verbose runtime logs**: During development, filter Android `logcat` or the iOS Xcode Console by `FlutterPatcher` to view detailed native engine logs for verification and loading.
