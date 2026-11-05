# CLI Reference

**English** | [简体中文](cli-zh.md)

The CLI ships with the plugin. Run it in a project that depends on `flutter_patcher`:

```bash
dart run flutter_patcher <command> [options]
```

This document lists every command and option. For the whole first-run flow see [Getting Started](getting-started.md); for going live see the [Production Playbook](production-playbook.md).

## Conventions

- **Project directory**: the current directory, or `--project`.
- **Output**: on success, a command prints one line of JSON on standard output, except `serve` (status lines on standard error) and `doctor` (a checklist, or JSON with `--json`). On failure, `build`, `patch` and `baseline` print one line of JSON with `code` and `message` on standard error; the other commands print `CODE: message`. Failures exit with `2`, except a failed `doctor` check, which exits with `1`. Error codes are explained in [Error Codes and Troubleshooting](troubleshooting.md).
- **Warnings** go to standard error as `WARNING: <code>: <text>` and do not fail the command.
- **Flutter SDK** (`build`, `patch`, `doctor`): Flutter on your `PATH`, or `--flutter-sdk <path>`.
- **Offline** (`build`, `patch`, `doctor`): `--offline` uses only verified local caches and no network; `patch --offline` also reads the baseline from the local cache only.
- **Cache** (`build`, `patch`, `doctor`): `--cache-dir <dir>` uses another cache directory, which must be under `~/.flutter_patcher` or the project's `.dart_tool/flutter_patcher`. On Windows the cache path may be at most 80 characters; when `~/.flutter_patcher` is longer, choose a directory under the project's `.dart_tool/flutter_patcher`.
- `-h` / `--help` shows a command's own help; `--version` shows the CLI version.

## Project settings: `flutter_patcher.yaml`

`keys init` writes this file: the project's public keys under `trust`, and a template whose other settings are commented out. Nothing in it is secret: **commit it**.

| Setting | Meaning | Default |
|---|---|---|
| `store` | Publication store, where `publish` writes patches and manifests. `file://` or `s3://` | `.flutter_patcher/updates/` in the project |
| `baseline_store` | Baseline store, written by `build` and read by `patch` and `publish`. `file://`, `s3://` or HTTPS | `.flutter_patcher/baselines/` in the project |
| `trust` | The `root`, `publisher` and `patch` public keys every host is built with. Written by `keys init` and `keys import` | |
| `signing` | `command`: a program that signs instead of the key store; see [Where private keys come from](#where-private-keys-come-from) | The key store |

Unknown settings or values of the wrong shape fail with `CONFIG_INVALID`. How to set up stores: [Production Playbook](production-playbook.md#configuring-storage); requirements per type: [Storage requirements](#storage-requirements).

## Directories

| Path | Contents | Back up? |
|---|---|---|
| `flutter_patcher.yaml` | Settings and the project's public keys | Commit it |
| `~/.flutter_patcher/keys/<id>/` | This machine's private keys of the project (the key store) | **Yes**, with `keys export --out <file>` |
| `.flutter_patcher/baselines/` | Default baseline store | **Yes**, or use durable storage |
| `.flutter_patcher/updates/` | Default publication store | As needed |
| `.dart_tool/flutter_patcher/releases/` | `build` outputs | No |
| `.dart_tool/flutter_patcher/patches/` | `patch` outputs | No |
| `~/.flutter_patcher/` (besides `keys/`) | Downloaded engines and tools, prepared Flutter SDK copies, baseline cache | No; it can be downloaded again |

## keys

A project has three Ed25519 key pairs, `root`, `publisher` and `patch`; their roles are in [How It Works](architecture.md#security-model). Their public keys live in `flutter_patcher.yaml`; their private keys never live in the project. `build` and `patch` need no private key: only `publish`, `serve` and `trust sign` sign.

### keys init

```bash
dart run flutter_patcher keys init
```

Creates the project's keys. The private keys go to this machine's key store, `~/.flutter_patcher/keys/<id>/keys.json` (mode 600 in a mode 700 directory on POSIX, readable by the current user only on Windows); the public keys go to `trust` in `flutter_patcher.yaml`.

- Refuses with `KEYS_ALREADY_CONFIGURED` when `flutter_patcher.yaml` already names keys: hosts already built would not trust new ones. On another machine, use `keys import`.
- Prints the public keys, never private keys. Back the private keys up right away with `keys export --out <file>`: a lost `root` or `patch` key cannot be replaced for hosts already shipped.
- `--out <file>` writes new keys to that new file only, leaving the key store and the project alone; with `--role publisher` only a publisher key, to [rotate](advanced.md#rotating-the-publisher-key) to.

### keys export and keys import

```bash
dart run flutter_patcher keys export --out <file>                  # a backup, or for another machine
dart run flutter_patcher keys import <file>
dart run flutter_patcher keys export --base64 --without-root       # one line for a CI secret
```

| Option | Description |
|---|---|
| `export --out <file>` | Write this machine's keys of the project to a new file (mode 600 on POSIX) |
| `export --base64` | Print them as one base64 line instead, for `FLUTTER_PATCHER_KEYS` |
| `export --without-root` | Leave out the root key, which only trust updates need |
| `import <file>` | Add a key bundle to this machine's key store; `-` reads it from standard input |
| `import --rotate` | Adopt the bundle's publisher key in place of the current one, after its trust update is published |

`import` refuses keys other than the ones `flutter_patcher.yaml` names (`KEYS_MISMATCH`). In a project without keys it writes their public keys there.

### keys status

Shows each key's public key and where its private key comes from: `key store`, `FLUTTER_PATCHER_KEYS`, `--key-file`, `signing.command` or `none`. It signs nothing.

### Where private keys come from

`publish`, `serve` and `trust sign` take each private key from the first of:

1. `--key-file <file>`: a key bundle file;
2. the `FLUTTER_PATCHER_KEYS` environment variable: a key bundle, as `keys export --base64` prints it;
3. `signing.command` in `flutter_patcher.yaml`;
4. this machine's key store.

A source may hold only some of the keys. A key other than the one `flutter_patcher.yaml` names fails with `KEYS_MISMATCH` instead of being skipped.

`signing.command` signs with a service that holds the keys, such as a KMS, HashiCorp Vault or a password manager, so the private keys never reach the machine:

```yaml
signing:
  command: my-signer --key "fp-$FLUTTER_PATCHER_SIGN_ROLE"
```

The command runs in the system shell (`sh`, or `cmd` on Windows, where variables are written `%FLUTTER_PATCHER_SIGN_ROLE%`) with `FLUTTER_PATCHER_SIGN_ROLE` (`root`, `publisher` or `patch`) and `FLUTTER_PATCHER_SIGN_PUBLIC_KEY` set. It reads the bytes to sign on standard input and prints their Ed25519 signature in base64; it has 60 seconds. Every signature is verified before use. The service must sign with pure Ed25519 (not Ed25519ph), as HashiCorp Vault transit and Google Cloud KMS `EC_SIGN_ED25519` keys do.
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
| `--assets <key>` | Override only these asset keys (repeatable) | Changed assets are selected |
| `--target <file>` | Entry file | `lib/main.dart` |
| `--out <dir>` | Output directory; must be new | `.dart_tool/flutter_patcher/patches/<timestamp>/` |
| `--baseline-store <uri>` | Read the baseline here instead of `baseline_store` in `flutter_patcher.yaml` | From `flutter_patcher.yaml` |

- `patch` needs only the source and the release's baseline: no private key, and no access to the publication store.
- Strategy, channel and the rest come from the baseline.
- The output directory holds `patch.draft` (the patch, not yet signed) and `patch.json` (the report). In the report, `changed` lists what changed and `warnings` lists what to look at.
- A draft has no sequence number yet: `publish` gives it one.
- Changes that cannot be patched fail the command; the rules are in [How It Works](architecture.md#what-can-be-patched).
- When you patch a bug fix, **keep the build number in `pubspec.yaml`**, or `patch` looks for a release that does not exist; or name it with `--version-code`.

## publish

Signs a patch made by `patch` and publishes it to the publication store. With `serve` and `trust sign`, the only commands that need private keys; see [Where private keys come from](#where-private-keys-come-from).

```bash
dart run flutter_patcher publish
```

| Option | Description | Default |
|---|---|---|
| `--patch <dir>` | The `patch` output to publish | The latest `patch` output |
| `--withdraw` | Withdraw that patch's release's published patches instead; see the [Production Playbook](production-playbook.md#withdrawing-a-patch) | |
| `--through <seq>` | With `--withdraw`: withdraw up to this sequence | The highest published |
| `--yes`, `-y` | Publish without asking | Preview, then ask; only preview when not interactive |
| `--seq <n>` | Publish with this sequence number, from 1 to 4294967295; it must exceed every sequence published or withdrawn for the release | The highest published or withdrawn + 1 |
| `--key-file <file>` | Sign with this key bundle first | |
| `--receipt <file>` | Also write the result to a new JSON file | |
| `--production --request <file>` | Advanced: run a publish or cleanup request file you wrote; see [Advanced Operations](advanced.md#cleaning-up-old-patches) | |

- Without `--yes` and without a terminal to ask in, it only previews: nothing is published, and it still exits with `0`.
- Each published patch gets the next sequence number: 1, 2, 3… for a release. `--seq` may skip ahead (after `--seq 10`, the next is 11), never back. A preview reserves no number. A request file sets `fields.patch_seq`, or leaves it out to number automatically.
- Before writing, it checks that the patch was built for that release, that the keys are the ones its host was built with, and that nobody changed the store since it was read.
- Publishing a patch that is already the release's latest does nothing and reports `already_published`.
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

- Publishes each new `patch` output to the project's publication store by itself; no need to run `publish`. An output published before, even if withdrawn since, is not published again when `serve` restarts.
- Prints what devices are offered whenever it changes, including withdrawals and patches you `publish` yourself.
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
| `--project <dir>` | Also check the project's Dart sources for CRLF line endings, and report where its private keys come from |
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

Only `publish` and `serve` use the publication store; `patch` does not.

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
| `FLUTTER_PATCHER_KEYS` | A key bundle (`keys export --base64`) to sign with, typically a CI secret |
| `FLUTTER_PATCHER_SIGN_ROLE`, `FLUTTER_PATCHER_SIGN_PUBLIC_KEY` | Set for `signing.command`: the key to sign with |
| `FLUTTER_PATCHER_S3_ENDPOINT` | HTTPS endpoint of an S3-compatible service such as Cloudflare R2. Not needed for AWS S3 |
| `FLUTTER_PATCHER_BASELINE_TOKEN` | Access token for an HTTPS baseline store, sent as `Authorization: Bearer` |
| Standard AWS CLI variables and config | S3 credentials and region, such as `AWS_PROFILE` and `AWS_REGION` |
