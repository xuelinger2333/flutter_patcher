# CLI Reference

**English** | [简体中文](cli-zh.md)

The CLI ships with the plugin. Run it in a project that depends on `flutter_patcher`:

```bash
dart run flutter_patcher <command> [options]
```

This document lists every command and option. For the whole first-run flow see [Getting Started](getting-started.md); for going live see the [Production Playbook](production-playbook.md).

## Conventions

- **Project directory**: the current directory, or `--project` (except `keys init`, which always uses the current directory).
- **Output**: on success, a command prints one line of JSON on standard output, except `serve` (status lines on standard error) and `doctor` (a checklist, or JSON with `--json`). On failure, `build`, `patch` and `baseline` print one line of JSON with `code` and `message` on standard error; the other commands print `CODE: message`. Failures exit with `2`, except a failed `doctor` check, which exits with `1`. Error codes are explained in [Error Codes and Troubleshooting](troubleshooting.md).
- **Warnings** go to standard error as `WARNING: <code>: <text>` and do not fail the command.
- **Flutter SDK** (`build`, `patch`, `doctor`): Flutter on your `PATH`, or `--flutter-sdk <path>`.
- **Offline** (`build`, `patch`, `doctor`): `--offline` uses only verified local caches and no network; `patch --offline` also reads the baseline from the local cache only.
- **Cache** (`build`, `patch`, `doctor`): `--cache-dir <dir>` uses another cache directory, which must be under `~/.flutter_patcher` or the project's `.dart_tool/flutter_patcher`. On Windows the cache path may be at most 80 characters; when `~/.flutter_patcher` is longer, choose a directory under the project's `.dart_tool/flutter_patcher`.
- `-h` / `--help` shows a command's own help; `--version` shows the CLI version.

## Project settings: `flutter_patcher.yaml`

Every setting is optional. `keys init` writes a template with all of them commented out.

| Setting | Meaning | Default |
|---|---|---|
| `store` | Publication store, where `publish` writes patches and manifests. `file://` or `s3://` | `.flutter_patcher/updates/` in the project |
| `baseline_store` | Baseline store, written by `build` and read by `patch` and `publish`. `file://`, `s3://` or HTTPS | `.flutter_patcher/baselines/` in the project |
| `keys` | Key directory, relative to this file | `flutter_patcher_keys` |

Unknown settings or non-string values fail with `CONFIG_INVALID`. How to set up stores: [Production Playbook](production-playbook.md#configuring-storage); requirements per type: [Storage requirements](#storage-requirements).

## Directories

| Path | Contents | Back up? |
|---|---|---|
| `flutter_patcher_keys/` | The three key pairs | **Yes**; never commit the private keys |
| `.flutter_patcher/baselines/` | Default baseline store | **Yes**, or use durable storage |
| `.flutter_patcher/updates/` | Default publication store | As needed |
| `.dart_tool/flutter_patcher/releases/` | `build` outputs | No |
| `.dart_tool/flutter_patcher/patches/` | `patch` outputs | No |
| `~/.flutter_patcher/` | Downloaded engines and tools, prepared Flutter SDK copies, baseline cache | No; it can be downloaded again |

## keys init

Creates three Ed25519 key pairs (`root`, `publisher`, `patch`); their roles are in [How It Works](architecture.md#security-model).

```bash
dart run flutter_patcher keys init
```

| Option | Description |
|---|---|
| `--out <dir>` | Write to another new directory instead of the project's `flutter_patcher_keys/` |

- Prints one line of JSON with the key file paths and public key fingerprints, never private keys.
- Refuses when the target exists; it never overwrites or rotates existing keys.
- On POSIX the key directory is mode 700 and private keys 600; on Windows the directory is granted to the current user only.
- With the default directory, it also writes the settings template when the project has no `flutter_patcher.yaml`.

## build

Builds a host app and saves its baseline to the baseline store.

```bash
dart run flutter_patcher build android
dart run flutter_patcher build ios        # Apple Silicon Mac only
```

| Option | Description | Default |
|---|---|---|
| `--strategy bytecode\|so` | Patch strategy, Android only; see [How It Works](architecture.md#two-patch-strategies) | `bytecode` |
| `--flavor <name>` | Flutter flavor | No flavor (recorded as `default`) |
| `--channel <name>` | Publication channel, written to the host policy; patches publish to the same channel only | `production` |
| `--version-code <n>` | Version number | The build number of `version` in `pubspec.yaml` |
| `--application-id <id>` | When the project does not declare exactly one application id | Read from the Gradle or Xcode project |
| `--target <file>` | Entry file | `lib/main.dart` |
| `--out <dir>` | Output directory; must be new | `.dart_tool/flutter_patcher/releases/<timestamp>/` |
| `--export-method <method>` | iOS only, passed to `flutter build ipa` | `app-store` |
| `--baseline-store <uri>` | Save the baseline here instead of `baseline_store` in `flutter_patcher.yaml` | From `flutter_patcher.yaml` |
| `--host-policy <file>` | Advanced: use a host policy you wrote instead of one derived from the project | |

- The build runs in an isolated copy of the project; your source and Flutter SDK are not modified.
- The output directory holds `app-release.apk` or `app-release.ipa`, the app you release.
- Rebuilding the same flavor and version: identical content reuses the existing baseline; different content fails with `BASELINE_RELEASE_CONFLICT`, so raise the version.
- With the default in-project baseline store, and no `--baseline-store`, it prints `WARNING: BASELINE_STORE_LOCAL`.
- Dart sources with CRLF line endings draw `WARNING: CRLF_DART_SOURCES`; see [Error Codes and Troubleshooting](troubleshooting.md) for why.

## patch

Compares your current source with a built release's baseline and builds a patch.

```bash
dart run flutter_patcher patch android
dart run flutter_patcher patch ios
```

| Option | Description | Default |
|---|---|---|
| `--version-code <n>` | The release to patch | The build number of `version` in `pubspec.yaml` |
| `--flavor <name>` | The release's flavor | `default` |
| `--seq <n>` | Patch sequence number; must exceed every sequence published for the release | Highest in the publication store + 1 |
| `--assets <key>` | Override only these asset keys (repeatable) | Changed assets are selected |
| `--target <file>` | Entry file | `lib/main.dart` |
| `--out <dir>` | Output directory; must be new | `.dart_tool/flutter_patcher/patches/<timestamp>/` |
| `--baseline-store <uri>` | Read the baseline here instead of `baseline_store` in `flutter_patcher.yaml` | From `flutter_patcher.yaml` |

- Strategy, channel and the rest come from the baseline.
- The output directory holds `patch.fptc` (the patch) and `patch.json` (the report). In the report, `changed` lists what changed and `warnings` lists what to look at.
- Changes that cannot be patched fail the command; the rules are in [How It Works](architecture.md#what-can-be-patched).
- When you patch a bug fix, **keep the build number in `pubspec.yaml`**, or `patch` looks for a release that does not exist; or name it with `--version-code`.

## publish

Signs a patch and publishes it to the publication store.

```bash
dart run flutter_patcher publish
```

| Option | Description | Default |
|---|---|---|
| `--patch <dir>` | The `patch` output to publish | The latest `patch` output |
| `--withdraw` | Withdraw that patch's release's published patches instead; see the [Production Playbook](production-playbook.md#withdrawing-a-patch) | |
| `--through <seq>` | With `--withdraw`: withdraw up to this sequence | The highest published |
| `--yes`, `-y` | Publish without asking | Preview, then ask; only preview when not interactive |
| `--receipt <file>` | Also write the result to a new JSON file | |
| `--production --request <file>` | Advanced: run a publish or cleanup request file you wrote; see [Advanced Operations](advanced.md#cleaning-up-old-patches) | |

- Without `--yes` and without a terminal to ask in, it only previews: nothing is published, and it still exits with `0`.
- Before writing, it checks again that the patch was built for that release, that the sequence does not conflict, and that nobody changed the store since it was read.
- While a publication commits, its request is saved in `.dart_tool/flutter_patcher/publish-pending.json`. If the commit stops midway, the store accepts nothing else until that publication finishes, so the next `publish` (or `serve`) in the project resumes it first.
- An S3 publication store needs a configured AWS CLI.

## serve

A patch server for development.

```bash
dart run flutter_patcher serve
```

| Option | Description | Default |
|---|---|---|
| `--port <port>` | Port on this computer, and the port `adb reverse` maps on phones | `8686` |

- Publishes each new `patch` output to the project's publication store by itself; no need to run `publish`.
- Listens on `127.0.0.1` only and serves only manifests and patch files.
- Every 2 seconds, runs `adb reverse` for newly connected Android devices.
- Works only with a `file://` publication store; comment out an `s3://` `store` in `flutter_patcher.yaml` while developing.
- Ctrl+C stops it.

## doctor

Checks that the toolchain is ready; on the first run it downloads and prepares what it needs.

```bash
dart run flutter_patcher doctor
```

| Option | Description |
|---|---|
| `--json` | Print a detailed JSON report |
| `--project <dir>` | Also check the project's Dart sources for CRLF line endings |
| `--baseline-store <uri>` | Check that the baseline store is reachable (write access is checked when building) |
| `--version-code <n>` `--flavor <name>` | With `--baseline-store`: check that release's baseline is complete |
| `--apk <file>` | Check that an APK's engine matches the selected Flutter version |

Exit codes: `0` passed, `1` a check failed, `2` usage error. `doctor` checks neither devices nor the update flow.

## Storage requirements

### Baseline store

| Type | Requirements |
|---|---|
| `s3://` | Requires an installed and configured AWS CLI. A missing object must return `NoSuchKey` (404), so besides read and write permissions the role needs `s3:ListBucket`; otherwise you get `BASELINE_STORE_UNREACHABLE`. For S3-compatible services such as Cloudflare R2, set `FLUTTER_PATCHER_S3_ENDPOINT` |
| HTTPS | The root returns `200` for `HEAD`; `GET` is supported; `PUT` with `If-None-Match: *` returns `201` when created and `412` when the object exists; missing objects return `404`. Pass the access token in `FLUTTER_PATCHER_BASELINE_TOKEN` |
| `file://` | A local directory or a network mount |

Baselines are append-only, so several build machines can share one baseline store.

### Publication store

| Type | Requirements |
|---|---|
| `s3://` | Requires an AWS CLI that supports conditional writes (`--if-match`, `--if-none-match`). Besides read, write and `s3:ListBucket`, cleaning up old patches needs `s3:DeleteObject`. The path must be a dedicated prefix under the bucket, each segment containing only letters, digits, `_` and `-`, for example `s3://my-bucket/my-app` |
| `file://` | A local directory or a network mount |

`patch` reads the publication store to choose the patch sequence, so the machine running `patch` also needs read access to it.

Contents of the publication store:

| Path | Contents | Served publicly |
|---|---|:---:|
| `manifests/<hash>.json` | Each release's current signed manifest | Yes |
| `objects/<operation id>/<hash>.fptc` | Patch files, never changed once written | Yes |
| `catalog.json` | Publication records used by the CLI | No; block it at the CDN |

The HTTPS server or CDN that serves it:

- returns content directly, without `3xx` redirects, which the client does not follow;
- gives `manifests/` a very short cache lifetime (such as `max-age=60`) or `no-cache`; `objects/` can be cached long term (such as `max-age=31536000, immutable`);
- may enable gzip; the client supports `Content-Encoding: gzip`;
- keeps manifests within 24,000 bytes; patch files must download within 2 minutes.
## Advanced commands

You rarely need these.

| Command | Purpose |
|---|---|
| `trust sign` / `trust publish` | Sign with the root key and publish a new set of publisher public keys, to rotate or revoke a publisher key; see [Advanced Operations](advanced.md#rotating-the-publisher-key) |
| `baseline --action fetch\|verify\|release` | Download, verify or look up baselines in the baseline store, for investigation |

## Environment variables

| Variable | Purpose |
|---|---|
| `FLUTTER_PATCHER_S3_ENDPOINT` | HTTPS endpoint of an S3-compatible service such as Cloudflare R2. Not needed for AWS S3 |
| `FLUTTER_PATCHER_BASELINE_TOKEN` | Access token for an HTTPS baseline store, sent as `Authorization: Bearer` |
| Standard AWS CLI variables and config | S3 credentials and region, such as `AWS_PROFILE` and `AWS_REGION` |
