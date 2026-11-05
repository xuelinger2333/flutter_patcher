<!-- ========================================== -->
<!-- doc/production-playbook.md (English)       -->
<!-- ========================================== -->

# Production Deployment Guide

**English** | [简体中文](production-playbook-zh.md)

This guide takes the patch flow you verified locally (see [Getting Started](getting-started.md)) to production. The core commands are exactly the same: `publish` still writes the distribution files into a local folder, and you then sync them to your live HTTPS static file host.

Steps marked **Optional** can be chosen to fit your infrastructure (see [Advanced and Optional Setups](#advanced-and-optional-setups)). Every option is described in the [CLI Reference](cli.md).

## Prerequisites

- The local flow from Getting Started works, including `keys init`.
- An HTTPS host that serves files directly (object storage + CDN, your own Nginx, or any static hosting). Hard requirements: it returns file contents directly, does not redirect, and does not cache `manifests/` for long. See [CLI Reference: Storage requirements](cli.md#storage-requirements).

## 1. Back Up the Signing Keys

Devices verify and load a patch only if it is signed with your private keys.

`keys init` saved the private keys on this computer in `~/.flutter_patcher/keys/<project id>/keys.json` (on Windows, `~` is the current user folder). The file is outside the project repository and is not committed with Git. If the private keys are lost, releases already live can no longer be patched.

Export the keys and keep the copy somewhere other than this computer (for example a company secrets vault or offline media):

```bash
dart run flutter_patcher keys export --out fp-keys.json
```

> **Optional**: CI/CD builds, publishing from several machines, or a KMS signing service: see [Multi-Machine and CI Publishing](#multi-machine-and-ci-publishing).

**Check**: the command prints `"status":"keys_exported"` and `file`, the path of the backup.

## 2. Set the Production Address

Switch the address the app checks for updates from the local `serve` to your HTTPS address.

1. In `flutter_patcher.yaml`, set the root address that serves the static files (where you upload in step 5):

   ```yaml
   url: https://cdn.example.com/my-app
   ```

   `build` then writes this address into the app, so `checkUpdate()` needs no code change. `publish` also reads the live manifest at this address first to find the current patch sequence.

2. Check that `android/app/src/main/AndroidManifest.xml` declares the internet permission (without it, the release build cannot go online to check for updates):

   ```xml
   <uses-permission android:name="android.permission.INTERNET" />
   ```

> **Optional**: roll out to a growing share of users? See [Staged Rollout Strategy](#staged-rollout-strategy).

## 3. Build and Ship the Store Release

Build an app that can receive patches and submit it to the store.

1. Build for production:

   ```bash
   dart run flutter_patcher build android    # build ios must run on an Apple Silicon Mac
   ```

2. Submit the generated `app-release.apk` (or `app-release.ipa`) to the store as usual.

**Check**:

- It prints `"status":"build_archived"`, and the `WARNING: URL_LOCAL` seen during local testing is gone.
- It still prints `WARNING: BASELINE_STORE_LOCAL`: the build baseline is kept in the project's `.flutter_patcher/` folder; read [Data You Must Not Lose](#data-you-must-not-lose).

## 4. Make and Publish a Patch

Fix the live bug, then produce a signed patch with the next sequence number.

1. Fix the code. Do not change `version` in `pubspec.yaml`.
2. Make the patch:

   ```bash
   dart run flutter_patcher patch android    # patch ios runs on any supported host; no Mac needed
   ```

3. Write the publication (it first shows a summary and waits for you to type `y`; in CI or other unattended runs, add `--yes`):

   ```bash
   dart run flutter_patcher publish
   ```

**Check**:

- `patch` prints `"status":"patch_created"`.
- `publish` prints `"status":"published"`, the increasing patch sequence `patch_seq` (1, 2, 3… within one release), and the manifest path `manifest` (such as `manifests/<hash>.json`).

**Note**: before assigning a sequence, `publish` reads this release's live manifest at `url`, so a new sequence is never below one devices may already hold. If the read fails, the command stops with `PUBLISH_URL_UNREACHABLE` and publishes nothing.

> **Optional**: patch a live release that is not the latest: see [Patching Older Live Releases](#patching-older-live-releases).

## 5. Sync to Static Storage

Upload the generated files to your live address so devices can download them.

After `publish`, the files to release are in `.flutter_patcher/updates/`. Upload two of its folders to the root address from step 2 (keeping the folder names), in this order:

1. `objects/` first
2. `manifests/` second

**Key constraints**:

- **Do not reverse the order**: if `manifests/` goes up first, a device that gets the new manifest immediately downloads the patch file it points to. With `objects/` not uploaded yet, the download returns 404 and this update fails; the device retries only the next time the app calls `checkUpdate`.
- After every `publish` (including the rollbacks and withdrawals below), sync the changes again.
- Do not upload `catalog.json` or `.publish.lock` (local state files of the CLI).

> **Optional**: let `publish` upload to S3/R2 directly, with no manual step: see [Publishing Straight to a Remote Bucket](#publishing-straight-to-a-remote-bucket).

**Check**: request `<live address>/<manifest path printed by publish>` directly and confirm it returns HTTP `200` with complete JSON. An app with this release installed applies the patch after its next update check and download, at its next cold start.

## Rolling Back and Withdrawing

What to do when a live patch goes wrong. Pick one option; afterwards, sync again as in step 5.

**Option A: withdraw completely (back to the version in the installed app)**

```bash
dart run flutter_patcher publish --withdraw
```

By default this withdraws **every** published patch of the release that your latest `patch` belongs to. To name another release, add `--patch <a patch folder of that release>`.

**Option B: go back to an earlier good patch**

Publish the earlier good patch again. It gets a new, higher sequence and reaches devices as a regular update:

```bash
dart run flutter_patcher publish --patch .dart_tool/flutter_patcher/patches/<target folder>
```

Earlier patches are kept in `.dart_tool/flutter_patcher/patches/` by default. If they were cleaned up, check out that code and run `patch` again. Do not publish the bad patch again, or devices will install it again.

**How devices apply it**: a device keeps only one patch, and accepts only a patch whose sequence is above the highest it has ever accepted. Withdrawing and republishing both publish a new manifest: a withdrawal manifest makes the device remove its patch, a republished one carries a new sequence. Once the app gets `hasUpdate == true` from `checkUpdate` and completes `applyPatch`, the change takes effect at the next cold start.

**Check**:

- Option A: the CLI prints `"action":"withdraw"`. After a cold start on the device, `FlutterPatcher.currentVersion` is `null` and `lastBootDiagnostic` is `noPatch`.
- Option B: the CLI prints a `patch_seq` above the bad patch's. After a cold start on the device, `currentVersion` is that new sequence and the stable code is back.

## Data You Must Not Lose

`.flutter_patcher/baselines/` in the project root holds the build baseline of each live release (compiled output, source hashes, dependencies, assets and public keys).

- **Back it up**: if a baseline is lost, that live release can never be patched again.
- **Alongside the keys**: once you are live, the only two things to keep are the exported private keys and the `baselines` folder.

Note: losing `.flutter_patcher/updates/` is not a problem. The manifests devices see are at `url`, and `publish` reads the current state from there before numbering.

## Advanced and Optional Setups

### Publishing Straight to a Remote Bucket

AWS S3 and S3-compatible object storage such as Cloudflare R2 are supported. Once configured, `publish` uploads the objects and keeps the publication records itself: no manual upload, and the records live in the bucket, so several machines and CI can work together.

1. On the publishing machine, install the AWS CLI and configure credentials (access key and secret) with write access. Permissions: [CLI Reference: Storage requirements](cli.md#storage-requirements). For third-party object storage, set its endpoint in an environment variable:

   ```bash
   export FLUTTER_PATCHER_S3_ENDPOINT="https://<account_id>.r2.cloudflarestorage.com"
   ```

2. Set the target paths in `flutter_patcher.yaml`:

   ```yaml
   store: s3://my-bucket/my-app
   baseline_store: s3://my-bucket/baselines
   ```

3. Access control: make the `my-app` prefix public read-only (its HTTPS address is the `url` from step 2); the `baselines` prefix must stay private.

**Check**: run the command below and confirm the `baseline_store` check passes; after that, `build` no longer prints `WARNING: BASELINE_STORE_LOCAL`.

```bash
dart run flutter_patcher doctor --baseline-store s3://my-bucket/baselines
```

### Multi-Machine and CI Publishing

Making patches and signed publishing are independent; only signing (`publish`, `serve`, `trust sign`) needs private keys:

| Role | Needs |
|---|---|
| Patch build machine (local or build server) | Source + the release's baseline (no private keys) |
| Publishing node (release machine or CI) | publisher and patch private keys + baseline + access to `url` |
| Key rotation | root private key (not needed day to day; keep it out of CI, offline) |

When several machines publish the same app, [publish straight to a remote bucket](#publishing-straight-to-a-remote-bucket): each publish sees the previous one at once, instead of getting a duplicate sequence because someone has not uploaded yet.

Getting the private keys to where they are used:

- **Another local computer**: run `keys export --out <file>` on the source machine and `keys import <file>` on the target.
- **CI (such as GitHub Actions)**: run `keys export --base64 --without-root` to get a single line without the root private key (it still contains the publisher and patch private keys; treat it as a secret), store it as a CI secret, provide it as the `FLUTTER_PATCHER_KEYS` environment variable, and run with `--yes` in the pipeline:

  ```bash
  dart run flutter_patcher publish --yes
  ```

- **KMS / external signing service**: configure `signing.command` to have an external service sign; the private keys never leave it. See [CLI Reference: Where private keys come from](cli.md#where-private-keys-come-from).

**Check**: on the publishing machine, run `dart run flutter_patcher keys status` and confirm the source of the publisher and patch keys is not `none`.

### Staged Rollout Strategy

Once a patch is live, every device on that release that reads the manifest can fetch it. To roll out by percentage, put a dynamic switch in front of the update check in the app (for example Firebase Remote Config or your own config service):

```dart
// Staged rollout gate
if (userBucket(userId) < rolloutPercent) {
  final check = await FlutterPatcher.checkUpdate();
  if (check.hasUpdate) {
    await FlutterPatcher.applyPatch(check.patch!);
  }
}
```

- `userBucket(userId)`: hashes a unique user identifier (such as a UUID) modulo 100, into 0–99.
- `rolloutPercent`: a percentage delivered by your backend config (for example `5` means 5%).

Both are yours to implement. Raise the share step by step (for example 1% → 10% → 30% → everyone), watching crash rates and the share of [boot diagnostics](crash-protection.md#boot-diagnostics) with `isHealthy == false`.

### Patching Older Live Releases

When several live releases need the fix, check out the code of that release and pass its build number when making the patch:

```bash
dart run flutter_patcher patch android --version-code <build number>
```

Then publish and sync as in steps 4 and 5. Each release has its own baseline and its own patch sequences.

## Built-in Protection

- **Tamper and integrity checks**: devices verify the signatures, SHA-256 hashes and target release of manifests and patches; files altered in transit or corrupted in a CDN cache are rejected.
- **No downgrades or replays**: devices persist the highest patch sequence they have accepted and install only higher ones; a withdrawn sequence never takes effect again.
- **Boot circuit breaker**: when a patch makes startup fail (a crash or ANR before the first frame, or an uncaught Dart exception within `verifyAfter` after it) `maxCrashCount` times (1 by default), the device turns the patch off and blocklists it, and runs the version in the installed app from the next cold start, so users are not stuck in repeated crashes. See [Crash Protection](crash-protection.md).
- **No overwrites under concurrency**: when several machines publish to the same bucket at once, conditional writes keep them from overwriting each other.
- **Interrupted publishing**: if `publish` stops midway, run it again with the same arguments in the same project to finish it.

## Related Reading

- [Rotating the publisher key](advanced.md#rotating-the-publisher-key): when the publisher private key leaks or is lost, replace it with a trust update signed by the root private key, without a new store release (the app must already apply trust updates).
- [Cleaning up old patches](advanced.md#cleaning-up-old-patches): delete expired patches from the publication store to free space.
- [Delivering manifests yourself](api-reference.md#delivering-manifests-yourself): deliver manifests and patches through your own authenticated API instead of a public static CDN.
