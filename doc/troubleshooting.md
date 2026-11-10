# Troubleshooting

**English** | [简体中文](troubleshooting-zh.md)

> Find the error code or warning a command printed, confirm its cause, and fix it; or find out why a device does not install or run a patch.

A command failed or warned, or a patch does not show up on a device. Search this page for the error code or the text you see. The common problems come first, each with its output, cause and fix; every code is listed in [All error codes](#all-error-codes). Problems on the device, which report through the Dart API instead of CLI codes, are in [On the device](#on-the-device).

| Symptom | Entries |
|---|---|
| `build` fails or warns | [`BASELINE_RELEASE_CONFLICT`](#baseline_release_conflict) · [`HOST_UNSUPPORTED`](#host_unsupported) · [`PUB_LOCKFILE_MISMATCH`](#pub_lockfile_mismatch) · [`WARNING: UNSIGNED`](#warning-unsigned) · [`WARNING: BASELINE_STORE_LOCAL`](#warning-baseline_store_local) |
| `patch` fails or writes no file | [Every file shows as changed](#every-file-shows-as-changed) · [`BASELINE_NOT_FOUND`](#baseline_not_found) · [`PATCH_BASELINE_INCOMPATIBLE`](#patch_baseline_incompatible) · [`BASELINE_STORE_UNREACHABLE`](#baseline_store_unreachable) · [`patch` succeeds without a file](#patch-succeeds-without-a-file) |
| `publish` or `serve` fails | [`PUBLISH_SEQUENCE_CONFLICT`](#publish_sequence_conflict) · [`KEYS_NOT_FOUND`](#keys_not_found) · [`SERVE_PORT_BUSY`](#serve_port_busy) |
| The device does not get or run the patch | [`checkUpdate` never finds an update](#checkupdate-never-finds-an-update) · [The patch is installed but does not run](#the-patch-is-installed-but-does-not-run) |

## How errors are printed

| Command | On stderr | Exit code |
|---|---|---|
| `build`, `patch`, `baseline` | One line of JSON with `code` and `message` | `2` |
| Other commands | `CODE: message` | `2` |
| `doctor`, when a check fails | `CODE: message` | `1` |
| Any command, for a warning | `WARNING: <CODE>: <text>` | Unchanged |

```json
{"command":"patch","status":"failed","code":"PATCH_NATIVE_CHANGE","message":"Native plugin/build hook changed: camera"}
```

`message` names the file, package or setting involved. Branch on `code`, not on `message`: messages change between versions, codes do not.

## Common issues

### Every file shows as changed

```json
{"command":"patch","status":"failed","code":"PATCH_NATIVE_CHANGE","message":"Application native files differ from the release only in line endings (CRLF/LF): …. Check out the sources with the line endings the host was built from (git core.autocrlf), then patch again."}
```

**How to tell**: you changed one line of Dart, and `changed` in the `patch` output lists every file, or `patch` fails with the message above.

**Cause**: source files are compared byte for byte with the baseline. Git for Windows converts line endings to `CRLF` by default, so a checkout on Windows differs in every file from a host built on Linux or macOS with `LF`.

**Fix**:

1. Add `* text=auto eol=lf` to `.gitattributes`, or set git `core.autocrlf` to the value used on the machine that built the host.
2. Check the sources out again.
3. Run `patch` again.

### `BASELINE_NOT_FOUND`

```json
{"command":"patch","status":"failed","code":"BASELINE_NOT_FOUND","message":"No archived release-…; check --flavor/--version-code, or pass --fingerprint for a legacy baseline."}
```

**How to tell**: `message` names the release `patch` looked for, by flavor, build number and ABI.

**Cause**: `patch` finds the baseline by flavor and build number, by default the number after `+` in `pubspec.yaml`. Either that pair was never built, or this machine reads another baseline store than `build` wrote to.

**Fix**: check in order:

1. The build number in `pubspec.yaml` is the live release's; otherwise pass `--version-code <n>`.
2. `--flavor` is the flavor used for `build`.
3. `baseline_store` in `flutter_patcher.yaml`, or `--baseline-store`, names the store `build` used.

If the baseline was deleted, that build can no longer be patched: ship a new store release.

### `BASELINE_RELEASE_CONFLICT`

```json
{"command":"build","status":"failed","code":"BASELINE_RELEASE_CONFLICT","message":"release-… is already archived with different content: …; bump versionCode."}
```

**How to tell**: you ran `build` again with the same flavor and build number, and the code or dependencies changed since the earlier build.

**Cause**: a release has one baseline. Identical content reuses the existing baseline; different content is refused, because replacing the baseline would leave the app already shipped without a matching one.

**Fix**:

1. If that build is live, raise the build number in `pubspec.yaml`, or pass `--version-code`, and build again.
2. If that build was never shipped, delete the object `message` names (`release-<flavor>-<version_code>-<abi>.tar.gz`) from the baseline store and build again.

### `PATCH_BASELINE_INCOMPATIBLE`

```json
{"command":"patch","status":"failed","code":"PATCH_BASELINE_INCOMPATIBLE","message":"This host was built with flutter_patcher 1.0; patch and publish for it with flutter_patcher 1.0.0+1."}
```

**How to tell**: `message` names one of the cases below.

**Cause**: the host cannot be patched by this flutter_patcher, or with the selected Flutter SDK.

**Fix**: by `message`:

| `message` | Fix |
|---|---|
| `This host was built with flutter_patcher 1.0; …` | Patch, publish and withdraw for that host with flutter_patcher 1.0.0+1; see [Upgrading from 1.0](upgrading.md) |
| `SDK differs from baseline`, or `SDK or engine build differs from the release` | A patch is built with the Flutter version that built its release. Switch to it, or pass `--flutter-sdk <path>` |
| A message that ends in `rebuild host`, or starts with `Rebuild this bytecode host` | The host lacks records this version needs. Build and ship a new host |
| From `publish`: `… is not a patch output of this flutter_patcher; patch again.` | The `--patch` directory was written by flutter_patcher 1.0. Run `patch` again |

### `BASELINE_STORE_UNREACHABLE`

```json
{"command":"patch","status":"failed","code":"BASELINE_STORE_UNREACHABLE","message":"Cannot tell whether … exists: … The store must report a missing object as HTTP 404 or S3 NoSuchKey (an S3 role needs s3:ListBucket)."}
```

**How to tell**: the store is reachable with the same credentials, for example `aws s3 ls` works on an object that exists, and `message` starts with `Cannot tell whether`.

**Cause**: the store must answer `404` (`NoSuchKey` on S3) for an object that does not exist. A role without `s3:ListBucket` gets `403` instead, and some CDNs behave the same, so flutter_patcher cannot tell a missing baseline from a refused request.

**Fix**:

1. Grant `s3:ListBucket` on the bucket to the role.
2. Run the command again.

Other messages under this code name the network or credential failure; the requirements per store type are in [Baseline store](cli.md#baseline-store).

### `patch` succeeds without a file

```json
{"command":"patch","status":"patch_created","file":null,"notice":"This host accepts only files signed by its patch key, which this machine does not have: `flutter_patcher keys import` it here and patch again, or run `flutter_patcher publish --patch` with this output where it is.", …}
```

**How to tell**: `patch` exits with `0`, and `file` in its output is `null`.

**Cause**: the host is signed, and no source on this machine holds its private key, so `patch` wrote only the draft.

**Fix**: do one of these:

1. Run `keys import <bundle>` on this machine, then `patch` again.
2. Run `publish --patch <output>` on a machine that has the key.

`keys status` shows which source would sign; see [Where the private key comes from](cli.md#where-the-private-key-comes-from).

### `PUBLISH_SEQUENCE_CONFLICT`

```text
PUBLISH_SEQUENCE_CONFLICT: The store holds 7-arm64-v8a.fptc numbered …, which devices may have taken already; this one would be …. Check this computer's clock, or publish with --seq ….
```

**How to tell**: the first number in `message` is at or above the second.

**Cause**: a file's sequence is the Unix time it was sealed. The file in the store was published by a computer whose clock runs ahead, or with a `--seq` above the current time. Devices that took it install only files numbered above it.

**Fix**:

1. Correct this computer's clock and run `publish` again.
2. If the stored number is still higher, publish with the `--seq` that `message` suggests.

### `KEYS_NOT_FOUND`

```text
KEYS_NOT_FOUND: No private key for patch key … in …. Run `flutter_patcher keys import`, set FLUTTER_PATCHER_KEYS or configure signing.command.
```

**How to tell**: `publish` fails before writing anything, and `keys status` prints `"private_key":"none"`.

**Cause**: the host is signed, and none of the sources `message` lists holds its private key.

**Fix**: do one of these:

1. Run `keys import <bundle>` with a bundle from `keys export --out <file>` on a machine that has the key.
2. In CI, set `FLUTTER_PATCHER_KEYS`; see [Keys in CI](advanced.md#keys-in-ci).

If every copy of the key is lost, hosts built with it accept no new patch file: see [3. Turn On Signing](production-playbook.md#3-turn-on-signing).

### `HOST_UNSUPPORTED`

```json
{"command":"build","status":"failed","code":"HOST_UNSUPPORTED","message":"build ios requires macOS with Xcode; patch ios runs on every host."}
```

**How to tell**: `message` names the detected computer, or says that `build ios` requires macOS.

**Cause**: the command does not run on this operating system or CPU.

**Fix**: run it on a supported computer:

| Command | Supported computers |
|---|---|
| `build android` | Linux x64, Windows x64, Apple Silicon Mac |
| `build ios` | Apple Silicon Mac |
| `patch android`, `patch ios` | Any of the above |

### `PUB_LOCKFILE_MISMATCH`

```json
{"command":"build","status":"failed","code":"PUB_LOCKFILE_MISMATCH","message":"pubspec.lock does not match pubspec.yaml or this shell's package host (https://pub.dev). Run `flutter pub get` in the project from this shell, then try again."}
```

**How to tell**: `message` names the package host of the current shell.

**Cause**: `pubspec.lock` does not match `pubspec.yaml`, or it was resolved with another package host, for example a `PUB_HOSTED_URL` mirror set in one terminal and not in another.

**Fix**:

1. Run `flutter pub get` in the project, in the terminal you build in.
2. Run the command again.

### `SERVE_PORT_BUSY`

```text
SERVE_PORT_BUSY: Port 8686 is in use on this computer; choose another with --port.
```

**How to tell**: `serve` exits at once.

**Cause**: another program, often an earlier `serve`, listens on the port.

**Fix**:

1. Stop that program, or run `serve --port <port>`.
2. With another port, map the phone's `8686` to it: `adb reverse tcp:8686 tcp:<port>`, because an app built without `url` checks `8686`.

### `WARNING: UNSIGNED`

```text
WARNING: UNSIGNED: this host accepts patch files that are not signed, so whoever can hand the app a file can run code in it. To sign, set trust.enabled to true in flutter_patcher.yaml (run `flutter_patcher init` first if it names no key) and build again.
```

**How to tell**: `flutter_patcher.yaml` names no patch key, or `trust.enabled` is `false`.

**Cause**: signing is off, which is how `init` leaves a project.

**Fix**:

1. If `flutter_patcher.yaml` has no `trust.patch`, run `dart run flutter_patcher init`.
2. Set `trust.enabled: true` in `flutter_patcher.yaml`.
3. Build again.

**If you ignore it**: the app installs any intact patch file of its build. This cannot be changed for a released host, so a signed host needs a new store release.

### `WARNING: BASELINE_STORE_LOCAL`

```text
WARNING: BASELINE_STORE_LOCAL: this host's baseline is kept only in …; every patch of the host needs it, so set baseline_store in flutter_patcher.yaml to a durable store.
```

**How to tell**: `flutter_patcher.yaml` has no `baseline_store`, and `build` ran without `--baseline-store`.

**Cause**: the baseline is saved only in the project, in `.flutter_patcher/baselines/`.

**Fix**: set `baseline_store`; see [2. Keep the Baselines](production-playbook.md#2-keep-the-baselines).

**If you ignore it**: when that directory is lost, this build can no longer be patched, and `patch` fails with `BASELINE_NOT_FOUND`.

### `checkUpdate` never finds an update

**How to tell**: `checkUpdate()` returns `hasUpdate: false`, or `serve` prints `A device checked for updates` and never `A device downloaded`.

**Cause**: the device requests `<url>/<fileName>` and takes only a file of its own build numbered above every file it accepted.

**Fix**: check in order:

1. The name: compare `(await FlutterPatcher.patchTarget).fileName` with the file you serve, and `url` with where it is served. Without `url` in the call, the app uses `url` from `flutter_patcher.yaml` at build time, so rebuild after changing it.
2. The upload: with a `file://` store, `publish` writes only to this computer. Upload the file to `<url>/<fileName>` after each `publish`.
3. The sequence: the file must be numbered above `patchTarget.acceptedSeq`. An old file uploaded again is not; run `patch` or `publish` again.
4. The build: the file must be for the installed build (`patchTarget.versionCode`, `flavor`, `channel`, `abi`, `fingerprint`). After users update the app, make a patch for the new build.
5. The server: it must answer over HTTPS without `3xx` redirects, with `404` when there is no file, and without a long cache time for `.fptc` files; see [Download server](cli.md#download-server).

To see how the device judges a file, pass its first 146 bytes to `FlutterPatcher.inspectPatch`: `reason` says why it is not new.

### The patch is installed but does not run

**How to tell**: `applyPatch` returned `ok: true`, and after a cold start the app still shows the old behavior.

**Cause**: the patch failed at startup and was turned off, or the app was upgraded.

**Fix**:

1. Read `FlutterPatcher.lastBootDiagnostic`: `status` says why the patch was skipped or rolled back.
2. Follow [Boot diagnostics](crash-protection.md#boot-diagnostics) for that `status`.

## All error codes

### Environment and toolchain

| Code | When it appears | Fix |
|---|---|---|
| `FLUTTER_NOT_FOUND` | `flutter` is not on `PATH` | Add Flutter to `PATH`, or pass `--flutter-sdk` |
| `FLUTTER_VERSION_INVALID` | The Flutter version cannot be read | Run `flutter --version` to check the SDK |
| `SDK_NOT_READY` | The selected Flutter SDK is not initialized, or its cache is incomplete | Run `flutter doctor` once, then retry |
| `SDK_PREPARE_FAILED` | The Flutter SDK copy flutter_patcher builds with cannot be prepared | Check the network and disk space, then retry |
| `ENGINE_ARTIFACT_MISSING` | No flutter_patcher engine exists for this Flutter version, or it cannot be downloaded | Use Flutter 3.47.0 to 3.47.9; check the network |
| `ENGINE_ARTIFACT_MISMATCH`<br>`ARTIFACT_HASH_MISMATCH`<br>`ARTIFACT_INVALID`<br>`ENGINE_MANIFEST_INVALID`<br>`TOOLS_ARTIFACT_MISSING`<br>`TOOLS_VERSION_UNSUPPORTED`<br>`YAML_CACHE_INVALID`<br>`YAML_GENERATION_FAILED`<br>`EMBEDDING_POM_UNAVAILABLE` | A downloaded engine or tool file is incomplete or fails its checksum | Check the network and retry; a damaged cache entry is set aside and downloaded again |
| `CACHE_INVALID` | A path the command uses (cache, project, store, keys, output or receipt) is or passes through a symbolic link | Use the real path |
| `HOST_UNSUPPORTED` | The command does not run on this OS or CPU | See [`HOST_UNSUPPORTED`](#host_unsupported) |
| `ANDROID_SDK_MISSING` | The Android SDK or its `build-tools` is not found | Set `ANDROID_HOME`, or run `flutter config --android-sdk` |
| `JAVA_HOME_INVALID` | `JAVA_HOME` does not point to a JDK | Correct `JAVA_HOME` |
| `XCODE_MISSING` | Xcode or the iOS platform is not installed | Install Xcode and the iOS platform in Xcode Settings |
| `DISK_FULL` | The disk is full | Free space and retry |
| `PUB_LOCKFILE_MISMATCH` | `pubspec.lock` does not match `pubspec.yaml` or the package host | See [`PUB_LOCKFILE_MISMATCH`](#pub_lockfile_mismatch) |
| `TOOL_FAILED` | A build tool exited with an error | Read the end of the tool's output in `message` |
| `CONFIG_INVALID` | `flutter_patcher.yaml` is invalid (an unknown setting, a value of the wrong type, a `trust` without a valid `patch`), an option is invalid, or `HOME`/`USERPROFILE` is not set | Correct what `message` names |
| `USAGE_ERROR` | The command line is wrong, including a command or option removed in 1.1 | Run the command with `--help`; see [Removed in 1.1](cli.md#removed-in-11) |
| `DOCTOR_FAILED` | `doctor` hit an unexpected error | Read `message` |
| `INTERFACE_INPUT_MISSING`<br>`INTERFACE_GENERATION_FAILED`<br>`INTERFACE_INDEX_FAILED`<br>`INTERFACE_VALIDATION_FAILED`<br>`INTERFACE_NOT_CONVERGED`<br>`INTERFACE_NO_PROGRESS` | The maintainer command `interface` failed | Maintainers only; read `message` |

### Keys and signing

| Code | When it appears | Fix |
|---|---|---|
| `KEYS_NOT_CONFIGURED` | `keys export` in a project without `trust.patch` | Run `init`, or `keys import` the project's key bundle |
| `KEYS_NOT_FOUND` | `publish` for a signed host and no source holds the private key; a `--key-file` or `keys import` file does not exist; `keys export` without the key in this machine's key store | See [`KEYS_NOT_FOUND`](#keys_not_found) |
| `KEYS_MISMATCH` | The first key source holds a key other than the host's; `keys import` got a key other than the one `flutter_patcher.yaml` names | Use the project's key. A host accepts only the key it was built with, so a new key needs new hosts |
| `KEYS_ALREADY_CONFIGURED` | `init` in a project that names no key and still has a pre-1.0 `flutter_patcher_keys/` directory | Run `keys import flutter_patcher_keys`, because released hosts accept only that key |
| `KEYS_BUNDLE_INVALID` | The file is not a key bundle or holds no patch key; or a file in `~/.flutter_patcher/keys/`, named in `message`, is damaged | Use a file written by `keys export` |
| `SIGNER_COMMAND_FAILED` | `signing.command` cannot start, exits non-zero, takes over 60 seconds, prints no base64 64-byte signature, or signs with another key | Run the command by hand with the same environment; see [Signing with a KMS or Signing Service](advanced.md#signing-with-a-kms-or-signing-service) |
| `KEYS_OUTPUT_EXISTS`<br>`KEYS_OUTPUT_UNAVAILABLE` | The output file exists, or the key store directory cannot be created | Choose a new file; check the permissions of `~/.flutter_patcher/keys` |
| `KEYS_PERMISSIONS_FAILED` | The private key file cannot be restricted to the current user | Use a file system that supports file permissions |
| `KEYS_IO_ERROR` | A key cannot be read or written | Check directory permissions and retry |

### `build`

| Code | When it appears | Fix |
|---|---|---|
| `BUILD_CONFIG_INVALID` | No `+` build number in `pubspec.yaml`, no single application id, an invalid `--host-policy` file, a `--flavor` or `--version-code` that differs from that policy, or an output directory that exists | Correct what `message` names, for example `version: 1.0.0+1`, `--application-id`, a new `--out` |
| `BUILD_PROJECT_INVALID` | The project layout is not supported, for example symbolic links in source packages | Change the project as `message` says |
| `BUILD_BOOTSTRAP_UNAVAILABLE` | The project does not depend on `flutter_patcher` | Run `flutter pub add flutter_patcher` |
| `BUILD_INPUT_CHANGED` | A source file changed while the build ran | Build again without editing files meanwhile |
| `BUILD_STEP_FAILED` | A Flutter build step failed | Read the end of the log and the log directory in `message` |
| `BUILD_APK_INVALID`<br>`BUILD_IPA_INVALID`<br>`ENGINE_INJECTION_FAILED` | The built app fails validation, for example its application id or build number differs from the host policy | On iOS, check code signing and `--export-method`; with `--host-policy`, check `application_id` and `version_code` |
| `BASELINE_RELEASE_CONFLICT` | This build number has a baseline with different content | See [`BASELINE_RELEASE_CONFLICT`](#baseline_release_conflict) |
| `BASELINE_CONTENT_CONFLICT` | Identical source produced different build output | Open an issue |
| `BUILD_FAILED` | An unexpected error | Read `message` |

### Baseline store

| Code | When it appears | Fix |
|---|---|---|
| `BASELINE_NOT_FOUND` | The release has no baseline in the store | See [`BASELINE_NOT_FOUND`](#baseline_not_found) |
| `BASELINE_STORE_UNREACHABLE` | The store cannot be reached, rejects the credentials, or answers `403` for a missing object | See [`BASELINE_STORE_UNREACHABLE`](#baseline_store_unreachable) |
| `BASELINE_STORE_PROTOCOL` | The store does not support create-if-absent writes | See [Baseline store](cli.md#baseline-store) |
| `BASELINE_INVALID` | The baseline is damaged | Restore the object from a copy; without one, ship a new store release |
| `BASELINE_FINGERPRINT_MISMATCH` | The baseline is not the requested release's | Check `--version-code`, `--flavor` and the Flutter version |
| `BASELINE_ARTIFACTS_MISSING`<br>`BASELINE_SCHEMA_UNSUPPORTED`<br>`BASELINE_NOT_RELEASE` | The baseline was written by an older, incompatible flutter_patcher | Build and ship a new host |
| `BASELINE_RELEASE_AMBIGUOUS` | An old-format record and a current one for the same release disagree | Delete the one `message` names |
| `BASELINE_OPERATION_FAILED` | An unexpected error | Read `message` |

### `patch`: changes a patch cannot carry

Why each is refused is in [What can be patched](architecture.md#what-can-be-patched).

| Code | When it appears | Fix |
|---|---|---|
| `PATCH_NATIVE_CHANGE` | Native code, a native plugin or a build hook changed, or a native dependency was added. A flutter_patcher version other than the host's counts as such a change | Revert the native change or ship a store release; patch with the flutter_patcher version the host was built with. Without a native change, see [Every file shows as changed](#every-file-shows-as-changed) |
| `PATCH_PINNED_PACKAGE_CHANGED` | A package that must stay at its baseline version, because it has native code or native code depends on it, changed version | Pin it to the baseline version under `dependency_overrides`, as `message` shows |
| `PATCH_FFI_UNSUPPORTED` | Code the patch carries calls native functions through `dart:ffi`; the patch carries the whole package, not only the changed lines | Move the FFI calls into a package the host keeps, such as a plugin, or ship a store release |
| `PATCH_UNSAFE` | The bytecode compatibility check failed | Read the violations in `message` |
| `PATCH_DYNAMIC_ICON` | Code builds a non-`const` `IconData` at run time | Use `const IconData(...)` or `Icons.*` |
| `PATCH_ASSET_DELETE_UNSUPPORTED` | An asset of the app was deleted | Restore the asset, or ship a store release |
| `PATCH_ENGINE_UNSUPPORTED` | The host's engine cannot install patch assets | Build and ship a new host |
| `PATCH_NO_CHANGES` | Nothing differs from the baseline | Save your edits; check the release you target |

### `patch`: warnings

The patch is made; part of it does not take effect everywhere.

| Code | When it appears | If you ignore it |
|---|---|---|
| `PATCH_NATIVE_ASSET_READER` | Native code reads an asset this patch changes | Native code still sees the app's original asset |
| `PATCH_BACKGROUND_ENTRY` | An entry point runs in a separate Flutter engine, such as a background task | That entry point runs the app's original code and assets |
| `PATCH_RESOURCE_SIZE` | The patch's assets exceed 16 MB in total | They stay in memory for the life of the process |

### `patch`: other errors

| Code | When it appears | Fix |
|---|---|---|
| `PATCH_BASELINE_INCOMPATIBLE` | The host cannot be patched by this flutter_patcher or Flutter version | See [`PATCH_BASELINE_INCOMPATIBLE`](#patch_baseline_incompatible) |
| `PATCH_TARGET_MISMATCH` | The entry file differs from the host's | Pass the `--target` used for `build` |
| `PATCH_DRAFT_INVALID` | The output directory holds no valid `patch.draft` | Pass an output of `patch` from this version, or run `patch` again |
| `PATCH_CONFIG_INVALID` | An option is invalid, or the output directory exists | Correct what `message` names |
| `PATCH_COMPILE_FAILED` | Dart compilation failed | Check that `flutter build` succeeds first |
| `PATCH_SOURCE_INVALID`<br>`PACKAGE_INPUT_INVALID` | The source package layout is not supported, for example symbolic links | Change the layout as `message` says |
| `PATCH_ASSET_INVALID`<br>`FONT_SUBSET_FAILED` | An asset or icon font cannot be processed | Fix the file `message` names |
| `PATCH_TOOL_FAILED` | A compile or diff tool failed | Read the tool output in `message` |
| `PATCH_PACKAGE_INVALID` | The patch cannot be packaged | Open an issue |
| `PATCH_FAILED` | An unexpected error | Read `message` |

### `publish` and `serve`

| Code | When it appears | Fix |
|---|---|---|
| `PUBLISH_CONFIG_INVALID` | No patch output to publish, unexpected arguments, a `--receipt` file that exists, or a `store` address with credentials, a query or a fragment | Run `patch` first or pass `--patch`; choose a new receipt file; correct `store` |
| `PUBLISH_SEQUENCE_CONFLICT` | The store's file has a sequence at or above the new one, or `--seq` is not from 1 to 4294967295 | See [`PUBLISH_SEQUENCE_CONFLICT`](#publish_sequence_conflict) |
| `PUBLISH_CONFLICT` | The store's file changed between reading and writing it, for example by another `publish` | Run `publish` again |
| `PUBLISH_STORE_UNAVAILABLE` | The AWS CLI is missing or failed, the store lacks conditional writes, or the role lacks `s3:ListBucket` | See [Publication store](cli.md#publication-store) |
| `PUBLISH_STORE_INVALID` | The `s3://` store is not a prefix below the bucket root made of letters, digits, `_` and `-`; or the store holds a file under this host's name that is not a patch file or exceeds 320 MiB | Correct `store`; remove the file `message` names |
| `PUBLISH_FAILED` | An unexpected error | Check the store and read `message` |
| `SERVE_PORT_BUSY` | The port is in use | See [`SERVE_PORT_BUSY`](#serve_port_busy) |

### Other warnings

| Code | When it appears | If you ignore it |
|---|---|---|
| `UNSIGNED`, `BASELINE_STORE_LOCAL` | `build`, with the setting missing | See the entries under [Common issues](#common-issues) |
| `ARTIFACT_CHECK_SKIPPED` | The artifact index cannot be downloaded | The command continues with the cached index |

## flutter_patcher 1.0 only

flutter_patcher 1.1.0 or newer never prints these codes. They come from flutter_patcher 1.0.0+1, which patches hosts built with 1.0.0; see [Upgrading from 1.0](upgrading.md).

| Code | When it appears | Fix, with 1.0.0+1 |
|---|---|---|
| `PUBLISH_BUSY`<br>`PUBLISH_COMMIT_UNKNOWN`<br>`PUBLISH_UPLOAD_FAILED`<br>`PUBLISH_DELETE_UNKNOWN` | An earlier publish or cleanup was interrupted | Run `publish`, or the same request file, again in the same project; it resumes from `.dart_tool/flutter_patcher/publish-pending.json` |
| `PUBLISH_URL_UNREACHABLE`<br>`PUBLISH_URL_INVALID` | `publish` cannot read the release's manifest at `url` | Fix `url` or the network; the address must answer `404` for a release with nothing published |
| `PUBLISH_CATALOG_INVALID`<br>`PUBLISH_CATALOG_FULL` | `catalog.json` is damaged, belongs to another application id, or reached 8 MiB | Use one store path per app and do not edit its files |
| `PUBLISH_MANIFEST_CONFLICT` | `manifests/<hash>.json` kept changing while it was rewritten | Run `publish` again |
| `PUBLISH_RETENTION_STALE`<br>`PUBLISH_OBJECT_CHANGED` | A cleanup plan is out of date | Run the dry run again |
| `PUBLISH_TARGET_MISMATCH` | The patch does not belong to the release | Make the patch again for that release |
| `PUBLISH_PATCH_INVALID` | The patch bundle is damaged or over 320 MB | Make the patch again with fewer assets |
| `PUBLISH_SIGNATURE_INVALID` | A signature does not verify against the baseline's patch key or `--root-public` | Publish with the keys the host was built with |
| `TRUST_CONFIG_INVALID`<br>`TRUST_INVALID`<br>`TRUST_REPLAY`<br>`TRUST_SCOPE_CONFLICT`<br>`TRUST_CONFLICT`<br>`TRUST_OUTPUT_EXISTS`<br>`TRUST_FAILED` | `trust sign` or `trust publish` failed | Follow `message`; for `TRUST_REPLAY`, raise `revision` above the published one |

## On the device

The device reports through the Dart API, not through the codes above.

| Symptom | Where to look |
|---|---|
| The patch does not install | `applyPatch`, `applyPatchBytes` and `applyPatchFile` return a `PatchApplyError`; each value is in [`PatchApplyError`](api-reference.md#patchapplyerror), and the rules a file must meet in [What a device accepts](api-reference.md#what-a-device-accepts) |
| No update is found | See [`checkUpdate` never finds an update](#checkupdate-never-finds-an-update) |
| The patch is installed but does not run | See [The patch is installed but does not run](#the-patch-is-installed-but-does-not-run) |
| Native verification and loading details | Filter Android `logcat` or the Xcode console by `FlutterPatcher` |
