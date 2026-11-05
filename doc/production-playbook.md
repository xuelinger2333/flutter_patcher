<!-- ========================================== -->
<!-- doc/production-playbook.md (English)       -->
<!-- ========================================== -->

# Production Playbook

**English** | [简体中文](production-playbook-zh.md)

The shortest path from a project that works locally ([Getting Started](getting-started.md)) to a live app. The commands are the same; what changes is where patches and baselines are stored and how devices reach them.

Lines marked **Your choice** are where your setup may differ; the alternatives are in [Variations](#variations). Every command option is in the [CLI Reference](cli.md).

## Before You Start

This guide assumes:

- The project works locally as in Getting Started, including `keys init`.
- A bucket on AWS S3 or an S3-compatible service such as Cloudflare R2, with a public HTTPS address, directly or through a CDN.
- The AWS CLI on the computer that publishes, signed in with write access to the bucket. Permissions and cache settings: [CLI Reference: Storage requirements](cli.md#storage-requirements).

## Step 1: Configure Storage

**Goal**: tell `flutter_patcher` where patches and baselines are kept.

The bucket holds two things under separate prefixes:

| Prefix | Holds | Read by | Public |
|---|---|---|---|
| Publication store, such as `my-app` | Signed manifests (`manifests/`) and patch files (`objects/`) | Devices | Yes |
| Baseline store, such as `baselines` | The build record of each live release; a release whose baseline is lost can no longer be patched | `patch` and `publish` | No |

**Do**:

1. Set both in `flutter_patcher.yaml`:

   ```yaml
   store: s3://my-bucket/my-app
   baseline_store: s3://my-bucket/baselines
   ```

   For an S3-compatible service, also set the `FLUTTER_PATCHER_S3_ENDPOINT` environment variable to its endpoint.

2. Make only the `my-app` prefix publicly readable, and note its HTTPS address, such as `https://cdn.example.com/my-app`. The app uses it in Step 3.

`store` is where `publish` writes, with your credentials; the HTTPS address is where devices read the same files, without any. Neither can be derived from the other, so you set both.

> **Your choice**: no object storage, or devices must download through your own API: [Other Storage Setups](#other-storage-setups).

**Check**: `dart run flutter_patcher doctor --baseline-store s3://my-bucket/baselines` passes its `baseline_store` check.

## Step 2: Back Up the Keys

**Goal**: keep the keys that sign patches safe. Devices install only patches signed with them.

`keys init` wrote the public keys to `flutter_patcher.yaml`, which you commit, and the private keys to `~/.flutter_patcher/keys/` on that computer.

**Do**:

```bash
dart run flutter_patcher keys export --out <file>
```

Keep the file somewhere safe, off this computer. A lost `root` or `patch` key cannot be replaced for apps already shipped; a lost `publisher` key can be replaced with the root key ([Advanced Operations](advanced.md#rotating-the-publisher-key)).

> **Your choice**: publishing from another computer, from CI, or through a signing service such as a KMS: [Publishing from Another Machine or CI](#publishing-from-another-machine-or-ci).

**Check**: `dart run flutter_patcher keys status` shows a source other than `none` for the publisher and patch keys.

## Step 3: Point the App at the Bucket

**Goal**: make the release build check your bucket instead of `serve`.

**Do**:

1. In the `checkUpdate` call from Getting Started, replace `http://127.0.0.1:8686` with the HTTPS address from Step 1:

   ```dart
   final check = await FlutterPatcher.checkUpdate('https://cdn.example.com/my-app');
   ```

2. Make sure `android/app/src/main/AndroidManifest.xml` still has the internet permission added in Getting Started; release builds have none without it.

> **Your choice**: let only a share of users install patches first: [Staged Rollouts](#staged-rollouts).

## Step 4: Ship the Release

**Goal**: put a release in the store that can be patched later.

**Do**:

1. Build:

   ```bash
   dart run flutter_patcher build android    # build ios on an Apple Silicon Mac
   ```

2. Submit `app-release.apk` (or `app-release.ipa`) from the output directory to the store.
3. Tag the source in Git. Patches for this release are made from it.

**Check**: `build` prints `"status":"build_archived"`, without `WARNING: BASELINE_STORE_LOCAL`.

## Step 5: Publish a Patch

**Goal**: fix the live release.

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
- `publish` prints `"status":"published"`, the `patch_seq` it assigned (1, 2, 3… per release), and `manifest`, the manifest's path in the store.
- `<HTTPS address>/<manifest>` answers `200`.

> **Your choice**: patch a release older than the latest: [Patching an Earlier Release](#patching-an-earlier-release).

## If a Patch Goes Wrong

**Goal**: stop a bad patch from running. Pick one of two ways.

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

## Variations

### Other Storage Setups

The steps above use object storage. The publication store can also be:

| Setup | `store` | Devices read from |
|---|---|---|
| Your own web server | `file://` and a local or network directory | Your server, after you copy the directory to it after each `publish`: `objects/` first, then `manifests/`; leave out `catalog.json` |
| Your own API | Object storage or `file://`, not public | Your API; the app hands the manifest and patch to [`applySignedManifest`](api-reference.md#delivering-manifests-yourself) |

`baseline_store` can be `file://` too: a directory that is backed up and that every machine running `patch` or `publish` can read.

### Publishing from Another Machine or CI

Only signing needs the private keys, that is `publish`, `serve` and `trust sign`; making patches does not:

| Who | Needs |
|---|---|
| Any machine that makes patches | The source and access to the baseline store; no private key |
| Whoever publishes | The publisher and patch keys, the publication store, and read access to the baseline store |
| Rotating the publisher key | The root key, kept offline |

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

Then `publish` as in Step 5. Each release has its own baseline and its own sequence numbers.

## Safeguards That Are Always On

- **Signature checks**: devices load only patches whose signatures, hashes and target release verify. Content changed in your storage or CDN is rejected.
- **No replays**: a device never installs a sequence at or below one it has accepted, and a withdrawn sequence never takes effect again.
- **Boot protection**: a patch that makes startup fail is turned off on that device, which runs its installed version at the next cold start. See [Crash Protection](crash-protection.md).
- **Concurrent publishing**: several machines can share the same stores; concurrent publishes never overwrite each other.
- **Interrupted publishing**: if `publish` stops midway, running it again in the same project finishes it.

## Advanced Operations

- [Rotating the publisher key](advanced.md#rotating-the-publisher-key): replace a lost or leaked publisher key without a new store release.
- [Cleaning up old patches](advanced.md#cleaning-up-old-patches): free space in the publication store.
- [Delivering manifests yourself](api-reference.md#delivering-manifests-yourself): when devices must download through your own API.