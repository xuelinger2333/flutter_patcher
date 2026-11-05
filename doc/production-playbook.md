<!-- ========================================== -->
<!-- doc/production-playbook.md (English)       -->
<!-- ========================================== -->

# Production Playbook

**English** | [简体中文](production-playbook-zh.md)

Production uses the same commands as [Getting Started](getting-started.md); what changes is where baselines and patches are stored and how devices reach them. Every command option is in the [CLI Reference](cli.md).

## Checklists

**Before the first store release with flutter_patcher**:

- [ ] `store` and `baseline_store` in `flutter_patcher.yaml` point to durable storage, and `build` no longer prints `WARNING: BASELINE_STORE_LOCAL` ([Configuring Storage](#configuring-storage)).
- [ ] The keys are backed up with `keys export`, and `flutter_patcher.yaml` is committed ([Keys on Machines and CI](#keys-on-machines-and-ci)).
- [ ] The publication store is served over HTTPS, and the app passes that address to `checkUpdate`.
- [ ] Android: the release build declares `android.permission.INTERNET`.
- [ ] The app submitted to the store is the output of `flutter_patcher build`, and its source is tagged in Git.

**Before each patch**:

- [ ] The source is the store release's tag plus the fix, and `version` in `pubspec.yaml` is unchanged.
- [ ] `changed` in the `patch` output lists only what you meant to change, and you have read any `warnings`.
- [ ] You know how to [withdraw](#withdrawing-a-patch) it.

## Configuring Storage

**Goal**: baselines and patches live in storage that outlasts any one computer, and devices download patches over HTTPS.

**Do**:

1. Set both stores in `flutter_patcher.yaml`:

   ```yaml
   store: s3://my-bucket/my-app
   baseline_store: s3://my-bucket/baselines
   ```

   | Setting | Holds | Types |
   |---|---|---|
   | `store` | Patches and signed manifests that devices download | `s3://`, `file://` |
   | `baseline_store` | The baseline of every live release; `patch` and `publish` read it | `s3://`, HTTPS, `file://` |

2. Serve the publication store over HTTPS, for example object storage behind a CDN, and use that address in the app:

   ```dart
   await FlutterPatcher.checkUpdate('https://cdn.example.com/my-app');
   ```

Permissions, protocol and CDN cache settings for each type are in [CLI Reference: Storage requirements](cli.md#storage-requirements).

**Check**:

- `dart run flutter_patcher doctor --baseline-store s3://my-bucket/baselines` passes its `baseline_store` check.
- `build` no longer prints `WARNING: BASELINE_STORE_LOCAL`.

A release whose baseline is lost can no longer be patched, so the baseline store needs the same care as a backup.

## Keys on Machines and CI

`keys init` writes the project's public keys to `flutter_patcher.yaml`: commit it. The private keys stay outside the project, in `~/.flutter_patcher/keys/` on the computer that ran it. Only signing needs them, that is `publish`, `serve` and `trust sign`; making patches does not:

| Who | Needs |
|---|---|
| Any machine that makes patches | The source and access to the baseline store; no private key |
| Whoever publishes | The publisher and patch keys, the publication store, and read access to the baseline store |
| Rotating the publisher key | The root key, kept offline |

**Back up** the keys right after `keys init`: `dart run flutter_patcher keys export --out <file>`, and keep the file somewhere safe. A lost `publisher` key can be replaced with the root key ([Advanced Operations](advanced.md#rotating-the-publisher-key)); a lost `root` or `patch` key cannot be replaced for hosts already shipped.

Whoever publishes uses these same keys; none of the ways below creates new ones. Pick the one that matches where you publish:

| Where you publish | How the keys get there |
|---|---|
| The computer that ran `keys init` | They are already there |
| Another computer | `keys export --out <file>` on the first one, then `keys import <file>` on the other |
| A CI service, if you use one (a hosted machine that builds and publishes for you, such as GitHub Actions) | Save the output of `keys export --base64 --without-root` as a CI secret, provide it as the `FLUTTER_PATCHER_KEYS` environment variable, and run `publish --yes`. The root key is left out: publishing never needs it |
| A signing service such as a KMS, when private keys must not exist as files | Configure `signing.command`: the service signs, and the keys never leave it. See [CLI Reference: Where private keys come from](cli.md#where-private-keys-come-from) |

**Check**: `dart run flutter_patcher keys status` on the publishing machine shows a source other than `none` for the publisher and patch keys.

## Release Workflow

**Goal**: ship a store release, then fix it with a patch.

**Do**:

1. Build the app, submit `app-release.apk` (or `app-release.ipa`) from the output directory to the store, and tag the source in Git:

   ```bash
   dart run flutter_patcher build android    # build ios on an Apple Silicon Mac
   ```

2. After fixing the issue on that tag's source, keeping `version` unchanged, make the patch:

   ```bash
   dart run flutter_patcher patch android    # patch ios runs on any supported computer
   ```

3. Publish it. The command shows a preview and writes only after you confirm; pass `--yes` when nobody is there to confirm, as in CI:

   ```bash
   dart run flutter_patcher publish
   ```

**Check**:

- `build` prints `"status":"build_archived"`; `patch` prints `"status":"patch_created"`.
- `publish` prints `"status":"published"`, the `patch_seq` it assigned (1, 2, 3… per release), and `manifest`, the manifest's path in the store.
- `<your HTTPS address>/<manifest>` answers `200`.

To patch an earlier live release, check out its tag and pass its build number with `--version-code`. Each release has its own baseline and its own sequence numbers.

## Staged Rollouts

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

## Withdrawing a Patch

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
