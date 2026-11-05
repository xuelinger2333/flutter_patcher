<!-- ========================================== -->
<!-- doc/production-playbook.md (English)       -->
<!-- ========================================== -->

# Production Playbook

**English** | [简体中文](production-playbook-zh.md)

The shortest path from a project that works locally ([Getting Started](getting-started.md)) to a live app. The commands are the same. `publish` still writes into the project; you upload what it writes to an HTTPS host of your choice, and devices download from there.

Lines marked **Your choice** are where your setup may differ; the alternatives are in [Variations](#variations). Every command option is in the [CLI Reference](cli.md).

## Before You Start

This guide assumes:

- The project works locally as in Getting Started, including `keys init`.
- An HTTPS host you can upload files to: object storage behind a CDN, your own web server, or any static hosting. It must return files without redirects and must not cache `manifests/` for long; see [CLI Reference: Storage requirements](cli.md#storage-requirements).

## Step 1: Back Up the Keys

**Goal**: keep the keys that sign patches safe. Devices install only patches signed with them.

`keys init` wrote the public keys to `flutter_patcher.yaml` and the private keys to `~/.flutter_patcher/keys/` on that computer.

**Do**:

```bash
dart run flutter_patcher keys export --out <file>
```

Keep the file somewhere safe, off this computer.

- A lost `patch` key cannot be replaced in apps already shipped: those releases can no longer be patched.
- A lost `root` key cannot be replaced in apps already shipped: the publisher key can no longer be rotated, though patches still publish.
- A lost `publisher` key can be replaced with the root key ([Advanced Operations](advanced.md#rotating-the-publisher-key)).

> **Your choice**: publishing from another computer, from CI, or through a signing service such as a KMS: [Publishing from Another Machine or CI](#publishing-from-another-machine-or-ci).

**Check**: `dart run flutter_patcher keys status` shows a source other than `none` for the publisher and patch keys.

## Step 2: Point the App at Your Host

**Goal**: make the release build check your host instead of `serve`.

**Do**:

1. Pick the address you will upload to in Step 5, such as `https://cdn.example.com/my-app`.
2. In the `checkUpdate` call from Getting Started, replace `http://127.0.0.1:8686` with it:

   ```dart
   final check = await FlutterPatcher.checkUpdate('https://cdn.example.com/my-app');
   ```

3. Make sure `android/app/src/main/AndroidManifest.xml` still has the internet permission added in Getting Started; release builds have none without it.

> **Your choice**: let only a share of users install patches first: [Staged Rollouts](#staged-rollouts).

## Step 3: Ship the Release

**Goal**: put a release in the store that can be patched later.

**Do**:

1. Build:

   ```bash
   dart run flutter_patcher build android    # build ios on an Apple Silicon Mac
   ```

2. Submit `app-release.apk` (or `app-release.ipa`) from the output directory to the store.
3. Tag the source in Git. Patches for this release are made from it.

**Check**:

- `build` prints `"status":"build_archived"`.
- It also prints `WARNING: BASELINE_STORE_LOCAL`: the release's baseline is in `.flutter_patcher/baselines/` in the project. Keep that directory; see [Keep These Two Directories](#keep-these-two-directories).

## Step 4: Publish a Patch

**Goal**: sign and number a fix for the live release.

**Do**:

1. Fix the issue on the tagged source, keeping `version` in `pubspec.yaml` unchanged.
2. Make the patch:

   ```bash
   dart run flutter_patcher patch android    # patch ios runs on any supported computer
   ```

3. Publish it. The command shows a preview and writes only after you confirm; pass `--yes` when nobody is there to confirm, as in CI:

   ```bash
   dart run flutter_patcher publish
   ```

**Check**:

- `patch` prints `"status":"patch_created"`.
- `publish` prints `"status":"published"`, the `patch_seq` it assigned (1, 2, 3… per release), and `manifest`, the manifest's path, such as `manifests/<hash>.json`.

> **Your choice**: patch a release older than the latest: [Patching an Earlier Release](#patching-an-earlier-release).

## Step 5: Upload

**Goal**: make the published patch reachable by devices.

`publish` wrote into `.flutter_patcher/updates/` in the project. Devices need two of its folders.

**Do**: upload them to the address from Step 2, keeping the folder names, in this order:

1. `objects/`
2. `manifests/`

Leave out `catalog.json` and `.publish.lock`: they are the CLI's own records, not for devices. Upload again after every `publish`, including withdrawals.

The order matters: a manifest uploaded before its patch points devices to a file that is not there yet, and they fail until their next check.

> **Your choice**: let `publish` write to a bucket itself, with no upload step: [Publishing Straight to a Bucket](#publishing-straight-to-a-bucket).

**Check**: `<your address>/<manifest from the publish output>` answers `200`. On a phone with the release installed, the patch applies at the next check and shows at the next cold start.

## If a Patch Goes Wrong

**Goal**: stop a bad patch from running. Pick one of two ways, then upload as in Step 5.

**Way 1: return devices to the installed version.**

```bash
dart run flutter_patcher publish --withdraw
```

This withdraws every published patch of the release your latest `patch` output belongs to. `--through <seq>` withdraws only up to that sequence; `--patch <dir>` names another release through one of its `patch` outputs.

**Way 2: return devices to an earlier, good patch.** Publish that patch's output again. It gets the next sequence and reaches devices as a regular update:

```bash
dart run flutter_patcher publish --patch .dart_tool/flutter_patcher/patches/<dir>
```

Outputs stay in `.dart_tool/flutter_patcher/patches/` until you delete them; without the output, check out that patch's source and run `patch` again. Do not publish the bad patch's output again: with a new sequence, devices would install it again.

Both are delivered as regular updates: a device acts on them when the app calls `applyPatch` for a `checkUpdate` result whose `hasUpdate` is `true`, and the change shows at its next cold start. Devices keep only one patch and never return to a lower sequence, which is why going back to an earlier patch means publishing it again.

**Check**:

- Way 1: `publish` prints `"action":"withdraw"`; after the next cold start, `FlutterPatcher.currentVersion` is `null` and `lastBootDiagnostic` is `noPatch`.
- Way 2: `publish` prints a `patch_seq` above the bad patch's; after the next cold start, `currentVersion` is that number.

## Keep These Two Directories

Both are in the project. Commit them to Git or include them in your backups.

| Directory | Holds | If it is lost |
|---|---|---|
| `.flutter_patcher/baselines/` | The build record of each live release | Releases built before the loss can no longer be patched |
| `.flutter_patcher/updates/` | What you upload, and `catalog.json`, the record of every sequence published | Numbering starts again from 1, and devices ignore any patch numbered at or below the one they have. Publish the next patch with `--seq` above every sequence published or withdrawn before, such as `publish --seq 100` |

## Variations

### Publishing Straight to a Bucket

`publish` can write to AWS S3 or an S3-compatible service such as Cloudflare R2 itself. There is no upload step, and the records live in the bucket, so several machines and CI can publish to the same place.

**Do**:

1. Install the AWS CLI on each publishing machine and sign it in with write access to the bucket. For an S3-compatible service, also set `FLUTTER_PATCHER_S3_ENDPOINT` to its endpoint. Permissions: [CLI Reference: Storage requirements](cli.md#storage-requirements).
2. Set both stores in `flutter_patcher.yaml`:

   ```yaml
   store: s3://my-bucket/my-app
   baseline_store: s3://my-bucket/baselines
   ```

3. Make only the `my-app` prefix public, and use its HTTPS address in Step 2. Baselines stay private.

`store` is where `publish` writes, with your credentials; the HTTPS address is where devices read the same files, without any.

**Check**: `dart run flutter_patcher doctor --baseline-store s3://my-bucket/baselines` passes its `baseline_store` check, and `build` no longer prints `WARNING: BASELINE_STORE_LOCAL`.

### Delivering Through Your Own API

When devices must download through your own API, the app fetches the manifest and patch from it and hands them to [`applySignedManifest`](api-reference.md#delivering-manifests-yourself). Publish as above; your API serves the files instead of a public host.

### Publishing from Another Machine or CI

Only signing needs the private keys, that is `publish`, `serve` and `trust sign`; making patches does not:

| Who | Needs |
|---|---|
| Any machine that makes patches | The source and the baselines; no private key |
| Whoever publishes | The publisher and patch keys, the baselines, and `.flutter_patcher/updates/` or the bucket |
| Rotating the publisher key | The root key, kept offline |

When more than one machine publishes, [publish straight to a bucket](#publishing-straight-to-a-bucket), so that they share one record of sequences.

Whoever publishes uses the same keys; none of the ways below creates new ones:

| Where you publish | How the keys get there |
|---|---|
| Another computer | `keys export --out <file>` on the first one, then `keys import <file>` on the other |
| A CI service (a hosted machine that builds and publishes for you, such as GitHub Actions) | Save the output of `keys export --base64 --without-root` as a CI secret, provide it as the `FLUTTER_PATCHER_KEYS` environment variable, and run `publish --yes`. The root key is left out: publishing never needs it |
| A signing service such as a KMS, when private keys must not exist as files | Configure `signing.command`: the service signs, and the keys never leave it. See [CLI Reference: Where private keys come from](cli.md#where-private-keys-come-from) |

**Check**: `dart run flutter_patcher keys status` on the publishing machine shows a source other than `none` for the publisher and patch keys.

### Staged Rollouts

**Goal**: let a share of users install a patch first, and widen it only while it stays healthy.

Once a patch is published, every device on that release can find it. The app decides who checks, for example from remote config:

```dart
if (userBucket(userId) < rolloutPercent) {
  final check = await FlutterPatcher.checkUpdate(url);
  if (check.hasUpdate) {
    await FlutterPatcher.applyPatch(check.patch!);
  }
}
```

`userBucket` and `rolloutPercent` are yours: a stable number from 0 to 99 per user, and a value from remote config.

**Do**: raise `rolloutPercent` step by step, for example 1% → 5% → 20% → 100%.

**Check** before each step: crash rates, and the share of [boot diagnostics](crash-protection.md#boot-diagnostics) that are not `isHealthy`.

### Patching an Earlier Release

Check out that release's tag, fix it, and pass its build number when making the patch:

```bash
dart run flutter_patcher patch android --version-code <build number>
```

Then publish and upload as in Steps 4 and 5. Each release has its own baseline and its own sequence numbers.

## Safeguards That Are Always On

- **Signature checks**: devices load only patches whose signatures, hashes and target release verify. Content changed on your host or CDN is rejected.
- **No replays**: a device never installs a sequence at or below one it has accepted, and a withdrawn sequence never takes effect again.
- **Boot protection**: a patch that makes startup fail is turned off on that device, which runs its installed version at the next cold start. See [Crash Protection](crash-protection.md).
- **Concurrent publishing**: machines publishing to the same bucket never overwrite each other.
- **Interrupted publishing**: if `publish` stops midway, running it again in the same project finishes it.

## Advanced Operations

- [Rotating the publisher key](advanced.md#rotating-the-publisher-key): replace a lost or leaked publisher key without a new store release.
- [Cleaning up old patches](advanced.md#cleaning-up-old-patches): free space in the publication store.
- [Delivering manifests yourself](api-reference.md#delivering-manifests-yourself): when devices must download through your own API.