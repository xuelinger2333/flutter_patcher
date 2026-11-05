<!-- ========================================== -->
<!-- doc/production-playbook.md (English)       -->
<!-- ========================================== -->

# Production Playbook

**English** | [简体中文](production-playbook-zh.md)

Production uses the same commands as local development; only where patches are stored and served changes. This guide covers the configuration needed to go live, plus release management features such as staged rollouts and withdrawing patches. For every command option, see the [CLI Reference](cli.md).

## Configuring Storage

Set two storage locations in `flutter_patcher.yaml`:

```yaml
store: s3://my-bucket/my-app
baseline_store: s3://my-bucket/baselines
```

| Setting | Purpose | Supported types |
|---|---|---|
| `store` | Publication store: holds patches and signed manifests for devices to download | `s3://`, `file://` |
| `baseline_store` | Baseline store: holds the baseline of every live release, used to create patches | `s3://`, HTTPS, `file://` |

Serve the publication store over HTTPS (for example, object storage behind a CDN) and use that address in your app:

```dart
await FlutterPatcher.checkUpdate('https://cdn.example.com/my-app');
```

> Creating patches for live releases needs the baseline store, and publishing them needs the private keys. Back up both; see [Keys on Machines and CI](#keys-on-machines-and-ci).

Permissions, protocol and CDN caching requirements for each store type are listed in [CLI Reference: Storage requirements](cli.md#storage-requirements).

## Keys on Machines and CI

`flutter_patcher.yaml` holds the project's public keys: commit it. Private keys are needed only to sign, by `publish` (and `serve`):

| Who | Needs |
|---|---|
| Any developer machine that makes patches | The source and access to the baseline store. No private key |
| The machine or CI job that publishes | The publisher and patch keys, and the publication store |
| Rotating the publisher key | The root key, kept offline |

- **Back up** the keys right after `keys init`: `dart run flutter_patcher keys export --out <file>`, and keep the file somewhere safe. A lost `root` or `patch` key cannot be replaced for hosts already shipped.
- **Another machine**: `dart run flutter_patcher keys import <file>`.
- **CI**: save the output of `dart run flutter_patcher keys export --base64 --without-root` as a secret, provide it as the `FLUTTER_PATCHER_KEYS` environment variable, and run `publish --yes`.
- **A KMS or signing service**: configure `signing.command`, and the private keys never leave it; see [CLI Reference: Where private keys come from](cli.md#where-private-keys-come-from).

## Release Workflow

1. Build the app and submit it to the store:

   ```bash
   dart run flutter_patcher build android
   ```

   The baseline is archived to the baseline store automatically.

2. After fixing the issue, create a patch:

   ```bash
   dart run flutter_patcher patch android
   ```

   `changed` in the output lists what the patch modifies, so you can confirm its scope.

3. Publish the patch:

   ```bash
   dart run flutter_patcher publish
   ```

   The command shows a preview and writes to the publication store only after you confirm; pass `--yes` in CI.

Tag each store release in Git, base patches on that tag's source, and keep the version in `pubspec.yaml` unchanged. To patch an earlier live release, check out its tag and pass its build number with `--version-code`.

## Security and Reliability

The following safeguards are always on and need no configuration:

- **Signature verification**: Devices load only signed, intact patches. If content in your storage or CDN is tampered with, devices reject it.
- **Rollback protection**: Withdrawn patches and patches older than the current one are never installed again.
- **Boot protection**: If a patch makes startup fail, the app runs its bundled version on the next cold start and disables the patch on that device. See [Crash Protection](crash-protection.md).
- **Concurrency safety**: Several build machines can share the same stores; concurrent publishes never overwrite each other.
- **Interruption recovery**: If a publish is interrupted, running `publish` again completes it.

## Staged Rollouts

Once a patch is published, every device on that release can see it. To roll out gradually, decide in your app, for example from remote config, whether to call `checkUpdate`:

```dart
if (userBucket(userId) < rolloutPercent) {
  final check = await FlutterPatcher.checkUpdate(url);
  if (check.hasUpdate) {
    await FlutterPatcher.applyPatch(check.patch!);
  }
}
```

Raise `rolloutPercent` step by step (for example 1% → 5% → 20% → 100%), checking crash rates and [boot diagnostics](crash-protection.md#boot-diagnostics) before each step.

## Withdrawing a Patch

```bash
dart run flutter_patcher publish --withdraw
```

This withdraws every published patch of the release your latest `patch` output belongs to. Devices remove the withdrawn patches when the app next applies updates, and run the bundled version after the next cold start.

- To withdraw only up to a given sequence: pass `--through <seq>`.
- To withdraw another release's patches: pass `--patch <dir>` with one of that release's `patch` outputs.

A withdrawal always returns devices to the installed version: they keep only one patch, and never go back to a lower sequence. To return them to an earlier patch instead, publish that patch's output again. It gets the next sequence and reaches devices as a regular update:

```bash
dart run flutter_patcher publish --patch .dart_tool/flutter_patcher/patches/<dir>
```

Outputs stay in `.dart_tool/flutter_patcher/patches/` until you delete them; without the output, check out that patch's source and run `patch` again.

A withdrawal is delivered as a regular update: it takes effect when your app calls `applyPatch` for a result whose `hasUpdate` is `true`, as in the example above. Patches published after it get higher sequence numbers.

## Advanced Operations

- [Rotating the publisher key](advanced.md#rotating-the-publisher-key): replace a lost or leaked publisher key without shipping a new app release.
- [Cleaning up old patches](advanced.md#cleaning-up-old-patches): free space in the publication store.
