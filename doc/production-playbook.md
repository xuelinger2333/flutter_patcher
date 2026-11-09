<!-- ========================================== -->
<!-- doc/production-playbook.md (English)       -->
<!-- ========================================== -->

# Production Deployment Guide

**English** | [简体中文](production-playbook-zh.md)

This guide takes the patch flow you verified locally (see [Getting Started](getting-started.md)) to production. The commands stay the same. Going live means: put the `.fptc` file where the app gets it, keep the baselines safe, and, optionally, sign patches. Every option is described in the [CLI Reference](cli.md).

## Prerequisites

- The local flow from Getting Started works.
- A way for the app to get patch files: an HTTPS host for the built-in downloader (`checkUpdate`), or your own API, push or other channel that hands the file to `applyPatchBytes` / `applyPatchFile`.

## 1. Decide Where the App Gets Patch Files

A patch is one file, such as `7-arm64-v8a.fptc`, or `7-paid-beta-arm64-v8a.fptc` for flavor `paid` and channel `beta` (see [Patch files](cli.md#patch-files)). Each build (version code, flavor, channel, ABI) has its own name, and the name stays the same for every patch of that build: a newer patch or a withdrawal replaces the file.

**With the built-in downloader**:

1. Set the address in `flutter_patcher.yaml` (create the file if the project has none):

   ```yaml
   url: https://cdn.example.com/my-app
   ```

   `build` writes it into the app; `checkUpdate()` then requests `https://cdn.example.com/my-app/<file name>`. The file name is the one `patch` wrote, and `(await FlutterPatcher.patchTarget).fileName` on the device.

2. The host must meet these requirements:

   | Requirement | Why |
   |---|---|
   | HTTPS | The downloader accepts plain HTTP only for `127.0.0.1`/`localhost` |
   | A short cache time for `.fptc` files, such as `Cache-Control: max-age=60` | The name never changes, so a long cache keeps serving the old file |
   | Returns the file directly, with `200` (or `206` for a range), `404` when there is none, and no redirects | The downloader does not follow redirects; any other status fails the check |

   Range requests are optional: `checkUpdate` asks for the first 146 bytes and stops reading after them either way.

**With your own delivery**: your server picks the file from what [`FlutterPatcher.patchTarget`](api-reference.md) reports (`fileName`, `versionCode`, `flavor`, `channel`, `abi`, `acceptedSeq`) and the app passes the bytes to `applyPatchBytes`. Transport security is then up to the app; see [3. Optional: Enable Signing](#3-optional-enable-signing).

## 2. Keep the Baselines

`build` records a baseline of every build it makes (compiled output, source hashes, dependencies, assets); every patch of that build is made against it. By default it is kept only in the project, in `.flutter_patcher/baselines/`, and `build` prints `WARNING: BASELINE_STORE_LOCAL`.

Point `baseline_store` at durable storage, such as a private S3 or R2 prefix (the [CLI Reference](cli.md) lists the storage requirements and credentials):

```yaml
baseline_store: s3://my-bucket/baselines
```

**Check**: `dart run flutter_patcher doctor --baseline-store s3://my-bucket/baselines` passes, and `build` no longer prints `WARNING: BASELINE_STORE_LOCAL`.

**If a baseline is lost**: that build can no longer be patched (`patch` fails with `BASELINE_NOT_FOUND`). Fix it with a new store release.

## 3. Optional: Enable Signing

Signing is recommended and off by default.

| Host | Who can run code in the app |
|---|---|
| Unsigned (the default) | Anyone who can hand the app a file. The built-in downloader enforces HTTPS; when the app fetches files itself, the transport is the app's responsibility |
| Signed | Only whoever holds the patch private key. Storage, CDN, transport and the app's way of fetching need not be trusted |

To sign, run this **before the build you ship**:

```bash
dart run flutter_patcher keys init
```

It creates one patch key: the private key in `~/.flutter_patcher/keys/<id>/keys.json` on this computer (on Windows, `~` is the user folder), the public key in `flutter_patcher.yaml` as `trust.patch`. Hosts built from then on accept only files signed by it; `build` stops printing `WARNING: UNSIGNED`. A host keeps the mode it was built with: hosts already shipped unsigned stay unsigned, and signed hosts never accept unsigned files.

Signing needs the private key on the machine that seals the file. `patch` and `publish` look for it in this order:

1. `--key-file <bundle>` (`publish` only)
2. The `FLUTTER_PATCHER_KEYS` environment variable, the base64 line from `keys export --base64`
3. `signing.command` in `flutter_patcher.yaml`, an external signer such as a KMS (it reads the bytes on stdin and prints a base64 Ed25519 signature; `FLUTTER_PATCHER_SIGN_ROLE` is `patch`)
4. The key store, `~/.flutter_patcher/keys/`

Move the key with `keys export --out <file>` and `keys import <file>`; `keys status` shows which source would sign. Without the key on a machine, `patch` there writes only the draft (`"file": null`, with a notice): `keys import` the key and patch again, or run `publish --patch <output>` on a machine with the key, which seals and signs it.

**To stop signing**: remove the `trust:` entry from `flutter_patcher.yaml`; hosts built from then on accept unsigned files. Signed hosts already shipped are unaffected: patching them still needs the original private key, so keep it for as long as they may need patches.

**If the private key is lost**: hosts built with it can no longer be patched. Remove the `trust:` entry from `flutter_patcher.yaml`, run `keys init` again and ship a new store release built with the new key.

## 4. Build and Ship the Store Release

```bash
dart run flutter_patcher build android    # build ios must run on an Apple Silicon Mac
```

Submit the generated `app-release.apk` (or `app-release.ipa`) to the store as usual.

**Check**: it prints `"status":"build_archived"`; `WARNING: URL_LOCAL` is gone once `url` is set, `WARNING: BASELINE_STORE_LOCAL` once `baseline_store` is set, and `WARNING: UNSIGNED` once signing is on.

## 5. Make and Deliver a Patch

1. Fix the code. Do not change `version` in `pubspec.yaml`.
2. Make the patch:

   ```bash
   dart run flutter_patcher patch android    # patch ios runs on any supported host; no Mac needed
   ```

   It prints `file`, the full path of the patch file, numbered with the current Unix time in seconds and signed when the host is signed.

3. Put that file where the app gets it, under its own name: at `<url>/<file name>` for `checkUpdate`, or in your own delivery. Nothing else is required.

4. Optional: let `publish` write it to a store instead:

   ```bash
   dart run flutter_patcher publish
   ```

   `publish` takes the newest patch output (or `--patch <dir>`), seals it again with a sequence numbered at publish time, the current Unix time in seconds (or `--seq N`), so files are ordered by the order you publish them, signs it when the host is signed, and writes `<file name>.fptc` to the store. It shows a summary and waits for `y`; in CI or other unattended runs add `--yes`. Without `--yes` and without a terminal it only previews (`"status":"preview"`) and writes nothing.

   The store is `.flutter_patcher/updates/` by default: upload `.flutter_patcher/updates/<file name>.fptc` to `url` (`publish` prints this reminder when `url` is set). With `store: s3://my-bucket/my-app` in `flutter_patcher.yaml`, `publish` writes to the bucket itself, through the AWS CLI (`FLUTTER_PATCHER_S3_ENDPOINT` for S3-compatible storage such as R2); serve that prefix publicly at `url`. Apps with their own delivery take the file from the store or from the patch output.

**Check**:

- `patch` prints `"status":"patch_created"` and `file`; `publish`, when used, prints `"status":"published"`, the `file` name and the `seq`.
- `curl -sI <url>/<file name>` returns `200`.
- An app of this build takes the patch at its next check and runs it from the next cold start; `FlutterPatcher.currentVersion` then returns the `seq`.

| `publish` result | Meaning and what to do |
|---|---|
| `"status":"already_published"` | The store already holds this patch; nothing written |
| `PUBLISH_SEQUENCE_CONFLICT` | The store holds a file of this build with a sequence at or above the new one, usually from a computer whose clock runs ahead. Fix the clock, or publish with the `--seq` the message suggests |
| `PUBLISH_CONFLICT` | The file in the store changed while publishing, for example another machine published. Run `publish` again |
| `KEYS_NOT_FOUND` | The host is signed and this machine has no private key for it; see [step 3](#3-optional-enable-signing) |

Each build has its own file, so patches for several live builds coexist. To patch an older live release, check out its code and pass its build number: `patch android --version-code <build number>`, then deliver it as above.

## Withdrawing and Rolling Back

| Goal | Do |
|---|---|
| Withdraw: devices go back to the version in the installed app | `patch android --withdraw` (or `ios`; add `--version-code <n>` for an older build), then deliver the file it prints like a patch. Or `publish --withdraw` (add `--patch <dir>` for another build than the newest patch's), which writes it to the store. Either way it is a withdrawal file, a file without payload, with a new sequence. A device that applies it drops its patch; the next cold start runs the installed version |
| Go back to an earlier good patch | `publish --patch .dart_tool/flutter_patcher/patches/<its output>`: the old patch is sealed again with a new, higher sequence and reaches devices as a regular update. Or check out that code and run `patch` again |
| Stop distributing | Stop offering the file (delete it from the host or from your API's answers). Devices that installed the patch keep it; this is not a withdrawal |
| One device | Call `FlutterPatcher.rollback()` in the app: it deletes the patch on that device and does not blacklist it |

Deliver the new file as in step 5 after each `patch --withdraw` or `publish`. Uploading an old `.fptc` again does nothing: its sequence is not above the one devices already accepted. If an earlier patch output was deleted, check out that code and run `patch` again.

**How devices decide**: a device installs a file only if it belongs to this build, is intact, is signed when the host is signed, and is numbered above every file it accepted before. Patches and withdrawals take effect at the next cold start.

**Check**:

- Withdrawal: `patch --withdraw` prints `"status":"withdrawal_created"`, `publish --withdraw` prints `"action":"withdraw"`. After a cold start, `FlutterPatcher.currentVersion` is `null` and `lastBootDiagnostic` is `noPatch`.
- Earlier patch: the CLI prints a `seq` above the bad patch's. After a cold start, `currentVersion` is that sequence and the earlier code runs.

## Staged Rollout

The file at `url` reaches every device of that build that checks. To roll out by share or by user, decide in the app or on your server: gate the check, or have your server choose which file to return.

```dart
// Staged rollout gate
if (userBucket(userId) < rolloutPercent) {
  final check = await FlutterPatcher.checkUpdate();
  if (check.hasUpdate) {
    await FlutterPatcher.applyPatch(check.patch!);
  }
}
```

- `userBucket(userId)`: hashes a unique user identifier modulo 100, into 0–99.
- `rolloutPercent`: a share delivered by your configuration service.

Both are yours to implement. Watch crash rates and the share of [boot diagnostics](crash-protection.md) with `isHealthy == false` as you raise the share.

## Upgrading from 1.0

| What | 1.1 behavior |
|---|---|
| Hosts already shipped with 1.0.0 | Unaffected. Patch, publish and withdraw for them only with flutter_patcher 1.0.0+1: in a checkout of that release with `flutter_patcher: 1.0.0+1` in `pubspec.yaml`. 1.1 rejects their baselines with `PATCH_BASELINE_INCOMPATIBLE` |
| The project | Keeps working: `trust.patch` in `flutter_patcher.yaml` is read (`root` and `publisher` are ignored), `url`, `store`, `baseline_store`, `signing.command` and the commands mean the same. 1.0 key bundles in the key store are found by their patch key. The next `build` makes a 1.1 host, signed with that patch key |
| The store | 1.0's `manifests/`, `objects/` and `catalog.json` stay; 1.0.0 hosts still read them. 1.1 writes `.fptc` files at the store root, next to them |
| Dart API | Removed: `SignedManifest`, `SignedUpdateResult`, `fetchSignedManifest`, `applySignedManifest`, `updatePublicationTrust`. Use `applyPatchBytes`, `applyPatchFile` or `checkUpdate` |
| CLI | Removed: `trust`, `publish --production` and `--request` (delete the file from the store instead), `keys import --rotate`, the key roles `root` and `publisher` |
| Version shown | `currentVersion` is now the file's sequence, a Unix timestamp |

## Built-in Protection

- **Integrity and target checks**: the device checks every file's length, format, target build and SHA-256 hash, and its signature on signed hosts; files altered in transit or corrupted in a cache are rejected.
- **No downgrades or replays**: devices keep the highest sequence they accepted and install only higher ones, so a withdrawn or replaced file never takes effect again.
- **Boot circuit breaker**: when a patch makes startup fail (a crash or ANR before the first frame, or an uncaught Dart exception within `verifyAfter` after it) `maxCrashCount` times (1 by default), the device turns the patch off and blacklists it, and runs the version in the installed app from the next cold start. See [Crash Protection](crash-protection.md).
- **No overwrites under concurrency**: `publish` replaces the file in the store only if it did not change meanwhile (`PUBLISH_CONFLICT`), and only with a higher sequence.

## Related Reading

- [CLI Reference](cli.md): every command, flag and `flutter_patcher.yaml` setting.
- [API Reference](api-reference.md): `patchTarget`, `inspectPatch`, `applyPatchBytes`, `applyPatchFile`, `checkUpdate`.
- [Troubleshooting](troubleshooting.md): error codes and recovery.
