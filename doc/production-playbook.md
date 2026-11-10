# Production Deployment Guide

**English** | [简体中文](production-playbook-zh.md)

In [Getting Started](getting-started.md), three settings were only good for development. Replace all three before you build the release you ship, because the address and signing go into the app, and the baseline is saved when the app is built.

| Setting | In development | In production | Warning from `build` | Step |
|---|---|---|---|---|
| Update address | The app asks `serve` on this computer for patches | The app asks your HTTPS server | None | [1](#1-decide-where-the-app-gets-patch-files) |
| Baseline store | The baseline is kept only in the project folder | The baseline is kept in durable storage | `BASELINE_STORE_LOCAL` | [2](#2-keep-the-baselines) |
| Signing | The app installs any patch file | The app installs only files you signed | `UNSIGNED` | [3](#3-turn-on-signing) |

Then build and ship the release (step 4) and deliver patches to it (step 5). The commands are the ones from Getting Started; their options are in the [CLI Reference](cli.md).

## 1. Decide Where the App Gets Patch Files

The app gets patch files in one of two ways:

| Way | The app calls | You provide |
|---|---|---|
| Built-in downloader | `checkUpdate` and `applyPatch` | An HTTPS address that serves the files |
| Custom delivery | `applyPatchBytes` or `applyPatchFile` | Your own channel, such as your API, and the code that fetches the file |

### With the built-in downloader

1. Pass the address to `checkUpdate`:

   ```dart
   final check = await FlutterPatcher.checkUpdate(url: 'https://cdn.example.com/my-app');
   ```

   The app then requests `<url>/<fileName>`, such as `https://cdn.example.com/my-app/7-arm64-v8a.fptc`, where `<fileName>` is the name `patch` gives the patch file of that build.

2. Make sure the server meets these requirements. The full list is in [Download server](cli.md#download-server).

   | Requirement | Why |
   |---|---|
   | HTTPS | The downloader accepts plain HTTP only for `127.0.0.1` and `localhost` |
   | A short cache time for `.fptc` files, such as `Cache-Control: max-age=60` | A new patch keeps the file name, so a long cache keeps serving the old file |
   | `200` with the file (or `206` for a range request), and `404` when there is none | The downloader does not follow redirects, and any other status, such as the `403` a private S3 or R2 bucket returns for a missing object, makes `checkUpdate` throw |

### With custom delivery

The app sends the fields of [`patchTarget`](api-reference.md#patchtarget) to your server, your server returns the file, and the app installs it with `applyPatchBytes`. The app code and the server side are in [Custom Delivery from Your Own Server](advanced.md#custom-delivery-from-your-own-server).

## 2. Keep the Baselines

`patch` makes each patch by comparing your code with the baseline that `build` saved for that build. By default `build` saves it only in the project's `.flutter_patcher/baselines/`, which a fresh checkout or another computer does not have. Point `baseline_store` at durable storage that every computer running `patch` can read, such as a private S3 or R2 prefix. Set it in `flutter_patcher.yaml`:

```yaml
baseline_store: s3://my-bucket/baselines
```

The requirements and credentials for each store type are in [Baseline store](cli.md#baseline-store).

**Check**: `dart run flutter_patcher doctor --baseline-store s3://my-bucket/baselines` passes, and `build` no longer prints `WARNING: BASELINE_STORE_LOCAL`.

> **Warning: a lost baseline ends patching for that build**
>
> `patch` then fails with `BASELINE_NOT_FOUND`, and nothing can recreate the baseline. The only way to fix that build is a new store release.

## 3. Turn On Signing

Without signing, the app installs any intact patch file made for its build, so anyone who can change the file on its way to the app can run code in the app. With signing, the app installs only files signed with your private key, so your server, CDN and network need not be trusted.

`init` already created the project's patch key: the public key is `trust.patch` in `flutter_patcher.yaml`, and the private key is in the key store of the computer that ran `init`. Signing is fixed into the app when it is built, so turn it on before the build you ship:

```yaml
trust:
  patch: <the key init wrote>
  enabled: true
```

Every app built afterwards accepts only files signed with this key, and `build` no longer prints `WARNING: UNSIGNED`. Apps built before stay unsigned.

### Sign on other computers

`patch` and `publish` sign on the computer where they run, so that computer needs the private key:

- Another computer: run `keys export --out <file>` here and `keys import <file>` there.
- CI: set `FLUTTER_PATCHER_KEYS`; see [Keys in CI](advanced.md#keys-in-ci).
- A KMS or signing service: see [Signing with a KMS or Signing Service](advanced.md#signing-with-a-kms-or-signing-service).

`keys status` shows which source would sign. On a computer without the key, `patch` prints `"file":null` and writes no patch file: import the key and run `patch` again.

> **Warning: a lost or leaked key needs a new store release**
>
> Apps built with a lost key accept no new patch file, because only that key can sign for them. Apps built with a leaked key run any file its holder signs. In both cases, delete the `trust:` entry, run `init` to create a new key, set `trust.enabled: true` and ship a new store release.

## 4. Build and Ship the Store Release

```bash
dart run flutter_patcher build android   # build ios runs on an Apple Silicon Mac
```

Submit `app-release.apk` (or `app-release.ipa`) from the output directory to the store.

**Check**: `build` prints `"status":"build_archived"` and neither the `BASELINE_STORE_LOCAL` nor the `UNSIGNED` warning.

## 5. Make and Deliver a Patch

1. Fix the code. Keep `version` in `pubspec.yaml` unchanged, because `patch` finds the build by its build number.
2. Make the patch:

   ```bash
   dart run flutter_patcher patch android   # patch ios runs on any supported computer
   ```

   `file` in the output is the path of the patch file. It is signed when the app is signed.

3. Upload that file under its own name to `<url>`, or hand it to your custom delivery.

**Check**: `curl -sI <url>/<fileName>` returns `200`. An app of this build installs the patch at its next check and runs it from the next cold start; `FlutterPatcher.currentVersion` then returns the file's `seq`.

To patch an older live release, check out its code and run `patch android --version-code <its build number>`. Each build has its own file name, so patches for several live builds do not replace each other.

### Optional: write to a store with `publish`

In development, `serve` hands the newest `patch` output straight to the phone; in production, `publish` writes it to a store, and your server offers it to the app.

```bash
dart run flutter_patcher publish
```

Check what it shows and type `y`. `"status":"published"` in the output means success; for any other result, see [Troubleshooting](troubleshooting.md).

| `store` in `flutter_patcher.yaml` | Where `publish` writes | What is left to do |
|---|---|---|
| Not set (default) | `.flutter_patcher/updates/` on this computer | Upload the files there to `<url>` |
| `s3://my-bucket/my-app` | That bucket; see [Publishing to S3](advanced.md#publishing-to-s3) | Nothing, as long as `<url>` serves that bucket's files |

- Unlike uploading the `patch` output directly, `publish` numbers the file with the time of publishing, so the file you publish last is always the one devices install.
- In CI, add `--yes`, because without a terminal `publish` only previews (`"status":"preview"`) and writes nothing.

## Delivering a rollback

| Goal | Do |
|---|---|
| Return devices to the version in the installed app | Run `patch android --withdraw` and deliver the file it prints as you deliver a patch, or run `publish --withdraw`, which writes the withdrawal file to the store |
| Return to an earlier good patch | Run `publish --patch .dart_tool/flutter_patcher/patches/<its output>`: the old patch is sealed again with a new, higher sequence and reaches devices as a regular update |
| Stop distributing a patch | Remove the file from the server, or from your server's answers. Devices that installed the patch keep running it, so to remove it from them, deliver a withdrawal |
| Remove the patch from one device | Call `FlutterPatcher.rollback()` in the app |

- For an older build or another output, see the options of [`patch`](cli.md#patch) and [`publish`](cli.md#publish).
- Deliver the new file as in [step 5](#5-make-and-deliver-a-patch) after each `patch --withdraw` or `publish`.
- Uploading an old `.fptc` again has no effect, because devices install only a file numbered above every file they accepted. The full rules are in [What a device accepts](api-reference.md#what-a-device-accepts).
- Patches and withdrawals take effect at the next cold start.

**Check**:

- Withdrawal: `patch --withdraw` prints `"status":"withdrawal_created"`; `publish --withdraw` prints `"action":"withdraw"`. After a cold start, `FlutterPatcher.currentVersion` is `null` and the `status` of `lastBootDiagnostic` is `noPatch`.
- Earlier patch: the CLI prints a `seq` above that of the bad patch. After a cold start, `currentVersion` is that sequence and the earlier code runs.

## Staged Rollout

The file at `url` reaches every device of that build that checks, so a rollout by share or by user is decided in the app or on your server: gate the check in the app, or have your server choose which file to return.

```dart
// Checks for a patch only for users inside the rollout share.
if (userBucket(userId) < rolloutPercent) {
  final check = await FlutterPatcher.checkUpdate();
  if (check.hasUpdate) {
    await FlutterPatcher.applyPatch(check.patch!);
  }
}
```

- `userBucket(userId)`: your function that hashes a unique user identifier modulo 100, into 0–99.
- `rolloutPercent`: the share, delivered by your configuration service.

As you raise the share, watch crash rates and the share of [boot diagnostics](crash-protection.md#boot-diagnostics) with `isHealthy == false`.

## Related

- [CLI Reference](cli.md): every command, option and `flutter_patcher.yaml` setting.
- [API Reference](api-reference.md): `patchTarget`, `inspectPatch`, `applyPatchBytes`, `applyPatchFile`, `checkUpdate`.
- [Troubleshooting](troubleshooting.md): error codes and recovery.
- [Crash Protection](crash-protection.md): how a device turns off a patch that makes startup fail.
- [Security model](architecture.md#security-model): what a device checks before it installs a file.
- [Upgrading from 1.0](upgrading.md): how to keep patching apps shipped with flutter_patcher 1.0.0.
