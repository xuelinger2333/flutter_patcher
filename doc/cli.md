# CLI Reference

**English** | [简体中文](cli-zh.md)

The CLI ships with the plugin. Run it in a project that depends on `flutter_patcher`:

```bash
dart run flutter_patcher <command> [options]
```

This document lists every command and option. For the whole first-run flow see [Getting Started](getting-started.md); for going live see the [Production Deployment Guide](production-playbook.md).

## Common workflows

Each workflow runs in the project root. Options are explained per command further down.

### Try a change on a phone over USB

```bash
dart run flutter_patcher patch android
dart run flutter_patcher serve          # leave running; patch again after each change
```

**Check**: `serve` prints `Offering patch <seq> (<file>, unsigned)` (or `signed`), then `A device downloaded <file>` once the app applies it. `serve` is a debugging aid only; see [serve](#serve).

### Hand a patch file to the app yourself

```bash
dart run flutter_patcher patch android
```

**Check**: the JSON names the patch file in `file`, such as `.dart_tool/flutter_patcher/patches/<dir>/7-arm64-v8a.fptc`. Give that file to the app in any way and pass it to `FlutterPatcher.applyPatchBytes` or `applyPatchFile`; see [API Reference](api-reference.md). When `file` is `null`, the host is signed and this machine lacks the patch key: `keys import` it here and patch again, or run `publish --patch <output>` where the key is.

`build` and `patch` are all a self-hosted delivery needs. For the built-in downloader, put the file at `<url>/<file name>`; see [Storage requirements](#storage-requirements) for what that server must do.

### Publish a patch to production

`publish` is optional: it writes the file to a store (`file://` or `s3://`), numbered at publish time, and guards against replacing a newer file.

```bash
dart run flutter_patcher patch android
dart run flutter_patcher publish        # preview, then confirm
```

**Check**: `publish` prints `"status":"published"` with the `file` and `seq` it wrote to the store. Storage setup: [Production Deployment Guide](production-playbook.md).

### Publish from CI

```bash
export FLUTTER_PATCHER_KEYS="<secret: the output of keys export --base64>"
dart run flutter_patcher patch android
dart run flutter_patcher publish --yes
```

**Check**: as above, with `"signed":true`; `keys status` in the job prints `"private_key":"FLUTTER_PATCHER_KEYS"`. Unsigned hosts need no secret.

### Withdraw a patch, or return to an earlier one

```bash
dart run flutter_patcher patch android --withdraw                                   # back to the installed version; deliver its file like a patch
dart run flutter_patcher publish --withdraw                                         # the same, written to the store
dart run flutter_patcher publish --patch .dart_tool/flutter_patcher/patches/<dir>   # back to an earlier patch
```

**Check**: the first prints `"status":"withdrawal_created"` and its `file`; the second prints `"action":"withdraw"`; the third prints a `seq` above the bad patch's. Uploading an older `.fptc` file again does nothing: devices accept only a higher `seq`.

### Patch an earlier live release

```bash
git checkout <that release's tag>
# fix the code
dart run flutter_patcher patch android --version-code <its build number>
dart run flutter_patcher publish
```

**Check**: `patch` prints `"status":"patch_created"` and a `file` named `<its build number>-…`.

### Make iOS patches on Linux or Windows

```bash
dart run flutter_patcher patch ios --baseline-store s3://my-bucket/baselines
```

`--baseline-store` is not needed when `baseline_store` in `flutter_patcher.yaml` already points to the store `build ios` used.

**Check**: `patch` prints `"status":"patch_created"` with `"abi":"ios-arm64"`.

## Conventions

- **Project directory**: the current directory, or `--project`.
- **Output**: on success, a command prints one line of JSON on standard output, except `serve` (status lines on standard error) and `doctor` (a checklist, or JSON with `--json`). On failure, `build`, `patch` and `baseline` print one line of JSON with `code` and `message` on standard error; the other commands print `CODE: message`. Failures exit with `2`, except a failed `doctor` check, which exits with `1`. Error codes are explained in [Error Codes and Troubleshooting](troubleshooting.md).
- **Warnings** go to standard error as `WARNING: <code>: <text>` and do not fail the command.
- **Flutter SDK** (`build`, `patch`, `doctor`): Flutter on your `PATH`, or `--flutter-sdk <path>`.
- **Offline** (`build`, `patch`, `doctor`): `--offline` uses only verified local caches and no network; `patch --offline` also reads the baseline from the local cache only.
- **Cache** (`build`, `patch`, `doctor`): `--cache-dir <dir>` uses another cache directory, which must be under `~/.flutter_patcher` or the project's `.dart_tool/flutter_patcher`. On Windows the cache path may be at most 80 characters; when `~/.flutter_patcher` is longer, choose a directory under the project's `.dart_tool/flutter_patcher`.
- `-h` / `--help` shows a command's own help; `--version` shows the CLI version.

## Removed in 1.1

| Removed | Instead |
|---|---|
| `trust sign`, `trust publish` | Nothing: there is no root or publisher key any more |
| `publish --production --request <file>` | Delete or replace the `.fptc` file in the store yourself |
| `keys init --role root\|publisher`, `keys import --rotate` | Nothing: the patch key is the only key |

They now fail as unknown commands or options (`USAGE_ERROR`).

## Patch files

`patch` and `publish` write one kind of file, FPTC v1, and `serve` serves it as written. The host's file always has the same name: `<version_code>-<abi>.fptc` for the default flavor and channel (`default`, `production`), for example `7-arm64-v8a.fptc`, and `<version_code>-<flavor>-<channel>-<abi>.fptc` otherwise, for example `7-paid-beta-arm64-v8a.fptc`. Flavors and channels contain only letters, digits and `_`, so no two hosts share a name. The app finds the name as `PatchTarget.fileName`.

| Offset | Bytes | Field |
|---|---|---|
| 0 | 4 | Magic `FPTC` (`0x46505443`) |
| 4 | 2 | Version `1` |
| 6 | 32 | Fingerprint of the host build |
| 38 | 4 | Sequence `seq`, uint32, at least 1 |
| 42 | 8 | Payload length L |
| 50 | 32 | SHA-256 of the payload |
| 82 | 64 | Ed25519 signature of bytes 0–81 followed by the payload; 64 zero bytes when unsigned |
| 146 | L | Payload: the patch ZIP. L = 0 is a withdrawal |

- A file is at most 320 MiB, and exactly 146 + L bytes.
- `seq` is the Unix time in seconds when the file was sealed, unless `--seq` gives one. A device installs a file only when its `seq` is above every `seq` it accepted for that host; see [API Reference](api-reference.md).
- A host built with a patch key accepts only files signed by it; an unsigned host accepts signed and unsigned files.

## Project settings: `flutter_patcher.yaml`

Every setting is optional, and nothing in it is secret. `keys init` creates the file from a template when it is missing.

| Setting | Meaning | Default |
|---|---|---|
| `url` | The address `build` writes into the app; `checkUpdate()` without `url` downloads `<url>/<fileName>` from it. Devices accept only HTTPS there, or HTTP to the device itself | `http://127.0.0.1:8686`, where `serve` offers patches; `build` warns `URL_LOCAL` |
| `store` | Publication store, where `publish` writes patch files. `file://` or `s3://` | `.flutter_patcher/updates/` in the project |
| `baseline_store` | Baseline store, written by `build` and read by `patch`. `file://`, `s3://` or HTTPS | `.flutter_patcher/baselines/` in the project |
| `trust` | `patch`: the base64 public key of the project's patch key. Hosts built while it is set accept only files it signed. Written by `keys init` and `keys import`. `root` and `publisher`, which flutter_patcher 1.0 wrote, are allowed and ignored | Not set: hosts accept unsigned files |
| `signing` | `command`: a program that signs instead of the key store; see [Where the private key comes from](#where-the-private-key-comes-from) | The key store |

Unknown settings, values of the wrong shape, and a `trust` without a valid `patch` fail with `CONFIG_INVALID`. Requirements per store type: [Storage requirements](#storage-requirements).

## Directories

| Path | Contents | Back up? |
|---|---|---|
| `flutter_patcher.yaml` | Settings and the project's public key | Optional; `keys import` writes the key again |
| `~/.flutter_patcher/keys/<id>/keys.json` | This machine's copy of the private patch key (the key store) | **Yes**, with `keys export --out <file>`; a lost key cannot be replaced for hosts already shipped |
| `.flutter_patcher/baselines/` | Default baseline store | **Yes**, or use durable storage: every patch of a host needs its baseline |
| `.flutter_patcher/updates/` | Default publication store | No |
| `.dart_tool/flutter_patcher/releases/` | `build` outputs | No |
| `.dart_tool/flutter_patcher/patches/` | `patch` outputs; `serve` serves the newest of each host | No |
| `~/.flutter_patcher/` (besides `keys/`) | Downloaded engines and tools, prepared Flutter SDK copies, baseline cache | No; it can be downloaded again |

## keys

Signing is optional. A project has at most one Ed25519 key pair, the patch key. Its public key lives in `flutter_patcher.yaml` (`trust.patch`); its private key never lives in the project. `build` needs no private key. `patch` and `publish` sign when the host has a patch key.

### keys init

```bash
dart run flutter_patcher keys init
```

Creates the patch key. The private key goes to this machine's key store, `~/.flutter_patcher/keys/<id>/keys.json` (mode 600 in a mode 700 directory on POSIX, readable by the current user only on Windows); the public key goes to `trust.patch` in `flutter_patcher.yaml`. Hosts built from then on accept only files it signed; hosts built before stay unsigned.

- Refuses with `KEYS_ALREADY_CONFIGURED` when `flutter_patcher.yaml` already names a patch key, or the project still has a `flutter_patcher_keys/` directory. On another machine, use `keys import`.
- Prints the public key, never the private key. Back it up with `keys export --out <file>`.
- `--out <file>` writes a new key to that new file only, leaving the key store and the project alone. `--role patch` is accepted with `--out`; it is the only role.

### keys export and keys import

```bash
dart run flutter_patcher keys export --out <file>      # a backup, or for another machine
dart run flutter_patcher keys import <file>
dart run flutter_patcher keys export --base64          # one line for a CI secret
```

| Option | Description |
|---|---|
| `export --out <file>` | Write this machine's patch key of the project to a new file (mode 600 on POSIX) |
| `export --base64` | Print it as one base64 line instead, for `FLUTTER_PATCHER_KEYS` |
| `export --without-root` | Accepted for 1.0 scripts; does nothing |
| `import <file>` | Add a key bundle to this machine's key store; `-` reads it from standard input; a directory reads the pre-1.0 `flutter_patcher_keys/` layout (`<dir>/patch/private-key.base64`) |

- `export` reads only this machine's key store, and needs `trust.patch` in `flutter_patcher.yaml` (`KEYS_NOT_CONFIGURED`).
- `import` refuses a key other than the one `flutter_patcher.yaml` names (`KEYS_MISMATCH`). In a project without a patch key it writes its public key there, so hosts built from then on are signed.
- Key bundles written by flutter_patcher 1.0, with root, publisher and patch keys, import and sign as they are; only their patch key is used. A bundle without a patch key fails with `KEYS_BUNDLE_INVALID`.

### keys status

```bash
dart run flutter_patcher keys status
```

Prints `config` (the settings file), `public_key` (`trust.patch`, or `null`) and `private_key`: where the private key comes from, `--key-file`, `FLUTTER_PATCHER_KEYS`, `signing.command`, `key store` or `none`. `<source> (other key)` means that source holds another key; an error code means it cannot be read. `--key-file <file>` includes that bundle. It signs nothing.

### Where the private key comes from

`patch` and `publish` take the private patch key from the first of:

1. `--key-file <file>` (`publish` only): a key bundle file;
2. the `FLUTTER_PATCHER_KEYS` environment variable: a key bundle, as `keys export --base64` prints it;
3. `signing.command` in `flutter_patcher.yaml`;
4. this machine's key store, where the bundle is found by its public key, including 1.0 directories.

The first source present is used. If it holds a key other than `trust.patch` of the host, the command fails with `KEYS_MISMATCH` instead of trying the next one. When no source exists, `patch` still succeeds without a file (`"file":null`), and `publish` fails with `KEYS_NOT_FOUND`.

`signing.command` signs with a service that holds the key, such as a KMS, HashiCorp Vault or a password manager, so the private key never reaches the machine:

```yaml
signing:
  command: my-signer --key "fp-$FLUTTER_PATCHER_SIGN_ROLE"
```

The command runs in the system shell (`sh`, or `cmd` on Windows, where variables are written `%FLUTTER_PATCHER_SIGN_ROLE%`) with `FLUTTER_PATCHER_SIGN_ROLE=patch` and `FLUTTER_PATCHER_SIGN_PUBLIC_KEY` set, and without `FLUTTER_PATCHER_KEYS`. It reads the bytes to sign on standard input and prints their 64-byte Ed25519 signature in base64; it has 60 seconds. Every signature is verified before use. The service must sign with pure Ed25519 (not Ed25519ph), as HashiCorp Vault transit and Google Cloud KMS `EC_SIGN_ED25519` keys do.

## build

Builds a host app and saves its baseline to the baseline store. It needs no private key.

```bash
dart run flutter_patcher build android
dart run flutter_patcher build ios        # Apple Silicon Mac only
```

| Option | Description | Default |
|---|---|---|
| `--strategy bytecode\|so` | Patch strategy, Android only; see [How It Works](architecture.md) | `bytecode` |
| `--flavor <name>` | Flutter flavor; letters, digits and `_` only | No flavor (recorded as `default`) |
| `--channel <name>` | Channel, written to the host policy and the patch file name; letters, digits and `_` only | `production` |
| `--version-code <n>` | Version number | The build number of `version` in `pubspec.yaml` |
| `--application-id <id>` | When the project does not declare exactly one application id | Read from the Gradle or Xcode project |
| `--target <file>` | Entry file | `lib/main.dart` |
| `--out <dir>` | Output directory; must be new | `.dart_tool/flutter_patcher/releases/<timestamp>/` |
| `--export-method <method>` | iOS only, passed to `flutter build ipa`. `development` installs on your registered devices; `app-store` needs a distribution certificate | `app-store` |
| `--baseline-store <uri>` | Save the baseline here instead of `baseline_store` in `flutter_patcher.yaml` | From `flutter_patcher.yaml` |
| `--host-policy <file>` | Advanced: use a host policy you wrote instead of one derived from the project; see below | |

- The build runs in an isolated copy of the project; your source and Flutter SDK are not modified.
- The output directory holds `app-release.apk` or `app-release.ipa`, the app you release.
- Rebuilding the same flavor and version: identical content reuses the existing baseline; different content fails with `BASELINE_RELEASE_CONFLICT`, so raise the version.
- Without `trust.patch` in `flutter_patcher.yaml`, it prints `WARNING: UNSIGNED`: whoever can hand the app a file can run code in it. To sign, run `keys init` and build again; the host's patch key is fixed when it is built.
- Without `url` in `flutter_patcher.yaml`, it prints `WARNING: URL_LOCAL`: `checkUpdate()` without `url` checks `serve`'s local address.
- With the default in-project baseline store, and no `--baseline-store`, it prints `WARNING: BASELINE_STORE_LOCAL`.

**Host policy file** (`--host-policy`): a JSON object of strings with exactly `schema` (`"2"`), `strategy` (`bytecode` or `so`; iOS `bytecode`), `abi` (`arm64-v8a` or `ios-arm64`), `application_id`, `version_code`, `flavor`, `channel` and `fptc_key` (the base64 patch public key, or `-` for an unsigned host). A flutter_patcher 1.0 policy (`"schema":"1"`) is accepted too: its `fptc_key` is kept and its `root_key` and `keys` are dropped. Anything else fails with `BUILD_CONFIG_INVALID`, and so do `--flavor` or `--version-code` that differ from the policy.

## patch

Compares your current source with a built release's baseline, builds a patch and seals it as the host's patch file. With `--withdraw` it writes a withdrawal of the host instead.

```bash
dart run flutter_patcher patch android
dart run flutter_patcher patch ios
dart run flutter_patcher patch android --withdraw
```

| Option | Description | Default |
|---|---|---|
| `--version-code <n>` | The release to patch | The build number of `version` in `pubspec.yaml` |
| `--flavor <name>` | The release's flavor | `default` |
| `--withdraw` | Write a withdrawal file of that host instead of a patch: devices that apply it drop their patch and run the installed version from the next cold start. It needs only the baseline; nothing is compiled | |
| `--assets <key>` | Override only these asset keys (repeatable) | Changed assets are selected |
| `--target <file>` | Entry file | `lib/main.dart` |
| `--out <dir>` | Output directory; must be new | `.dart_tool/flutter_patcher/patches/<timestamp>/` |
| `--baseline-store <uri>` | Read the baseline here instead of `baseline_store` in `flutter_patcher.yaml` | From `flutter_patcher.yaml` |

- Strategy, channel and patch key come from the baseline.
- The output directory holds `patch.draft` (the patch before sealing), `patch.json` (the report) and the patch file, named as in [Patch files](#patch-files). In the report, `changed` lists what changed, `warnings` lists what to look at, and `patch_key` is the host's patch key or `-`.
- The JSON adds `file` (the patch file's full path), `seq` (the Unix time it was sealed), `sealed_at` (that time in UTC) and `signed`.
- With `--withdraw`, the output directory holds `patch.json` (`"status":"withdrawal_created"`) and the withdrawal file under the same name; the JSON has the same `file`, `seq` and `signed`.
- A signed host whose private key no source on this machine holds: `patch` still succeeds, with `"file":null` and a `notice`. `keys import` the key here and patch again, or run `publish --patch <output>` on a machine with the key.
- `patch` does not write to the publication store; only `publish` does.
- A baseline of a host built with flutter_patcher 1.0 fails with `PATCH_BASELINE_INCOMPATIBLE`: patch that host with flutter_patcher 1.0.0+1.
- Changes that cannot be patched fail the command; the rules are in [How It Works](architecture.md).
- When you patch a bug fix, **keep the build number in `pubspec.yaml`**, or `patch` looks for a release that does not exist; or name it with `--version-code`.

## publish

The optional release command. Seals a `patch` output again with a `seq` numbered at publish time, so files are ordered by the order you publish them, and writes it to the publication store as `<fileName>`, replacing the file there only with a newer one.

Signed and unsigned hosts go through the same flow; the host's baseline decides whether the file is signed. A signed host needs the private key from `--key-file`, `FLUTTER_PATCHER_KEYS`, `signing.command` or the key store ([Where the private key comes from](#where-the-private-key-comes-from)); without one, `publish` fails with `KEYS_NOT_FOUND` before writing anything.

```bash
dart run flutter_patcher publish
```

| Option | Description | Default |
|---|---|---|
| `--patch <dir>` | The `patch` output to publish | The newest output under `.dart_tool/flutter_patcher/patches/` |
| `--withdraw` | Write a withdrawal for that output's host instead: devices that apply it drop their patch and run the installed version from the next cold start. An output of `patch --withdraw` is published as a withdrawal without it | |
| `--yes`, `-y` | Publish without asking | Preview, then ask; only preview when not interactive |
| `--seq <n>` | Sequence of the file, from 1 to 4294967295; it must exceed the `seq` of the file the store holds | The current Unix time in seconds |
| `--key-file <file>` | Sign with this key bundle first | |
| `--receipt <file>` | Also write the result to a new JSON file | |
| `--project <dir>` | The project | The current directory |

The result has `action` (`publish` or `withdraw`), `file`, `store`, `signed`, `seq` and `status`:

| `status` | When |
|---|---|
| `already_published` | The store already holds this draft for this host (or, with `--withdraw`, a withdrawal). Nothing is written; `seq` is the stored one |
| `preview` | No `--yes` and no terminal to ask in, or the answer was not `y`. Nothing is written; it exits with `0` |
| `published` | The file was written |

- A store file of this name with a `seq` not below the new one fails with `PUBLISH_SEQUENCE_CONFLICT`: check this computer's clock, or pass `--seq` above the stored one.
- If the store file changes between reading and writing, it fails with `PUBLISH_CONFLICT`; run `publish` again.
- `--withdraw` also works when the store holds nothing for the host.
- To return to an earlier patch, publish its output again with `--patch`: it gets a new, higher `seq`.
- After publishing to a `file://` store with `url` set, it prints where to upload the file: devices see nothing until `<url>/<fileName>` serves it.
- `--receipt` is written only for a `published` result. Its file must not exist, or `publish` fails with `PUBLISH_CONFIG_INVALID` before doing anything.
- An S3 publication store needs a configured AWS CLI.

## serve

A debugging aid for development. It serves the newest file `patch` wrote for each host, a patch or a withdrawal, exactly as written.

```bash
dart run flutter_patcher serve
```

| Option | Description | Default |
|---|---|---|
| `--port <port>` | Port on this computer, and the port `adb reverse` maps on phones. Apps built without `url` check `8686`; map it with `adb reverse tcp:8686 tcp:<port>` | `8686` |
| `--project <dir>` | The project | The current directory |

- For each host, serves the file of its newest output under `.dart_tool/flutter_patcher/patches/`; outputs written elsewhere with `patch --out` are not served. Each new `patch` run is picked up within about 2 seconds while `serve` keeps running.
- It does not publish, write the publication store, renumber or sign anything, and works whatever `store` `flutter_patcher.yaml` names. Devices verify the files as they verify any other.
- Prints `Offering patch <seq> (<file>, signed|unsigned)` or `Offering a withdrawal of <file> (signed|unsigned, <seq>)` whenever the newest output of a host changes.
- When a host's newest output has no file (a signed host whose key is not on this machine), it prints `Not offering <file>: ...` and serves nothing for that host, never an older file. Run `keys import` and patch again.
- Listens on `127.0.0.1` only and serves only `GET /<fileName>`, with `Range: bytes=0-<n>` answered as `206`; anything else is `404`.
- Every 2 seconds, runs `adb reverse` for newly connected Android devices.
- iOS devices cannot reach `127.0.0.1` of the computer: expose the port over HTTPS (for example `cloudflared tunnel --url http://127.0.0.1:8686`) and pass that address to `checkUpdate(url: …)`.
- Ctrl+C stops it.

## doctor

Checks that the toolchain is ready; on the first run it downloads and prepares what it needs.

```bash
dart run flutter_patcher doctor
```

| Option | Description |
|---|---|
| `--json` | Print a detailed JSON report |
| `--project <dir>` | Also report where the project's private patch key comes from |
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
| `s3://` | Requires an AWS CLI with conditional writes (`put-object --if-match`, `--if-none-match`) and permission to get and put objects under the prefix, plus `s3:ListBucket`: without it a missing file reads as access denied and `publish` fails with `PUBLISH_STORE_UNAVAILABLE`. The path must be a dedicated prefix under the bucket, each segment containing only letters, digits, `_` and `-`, for example `s3://my-bucket/my-app` |
| `file://` | A local directory or a network mount |

Only `publish` uses the publication store. It holds one file per host at its root, named as in [Patch files](#patch-files); a `file://` store also holds `.publish.lock`, which need not be served. What flutter_patcher 1.0 wrote there (`manifests/`, `objects/`, `catalog.json`) is neither read nor changed, and keeps serving 1.0 hosts.

The HTTPS server or CDN that `checkUpdate` downloads from, whether `publish` or you put the file there:

- answers `GET <url>/<fileName>` with the file (`200`, or `206` for the requested range; range support is not required), and `404` when there is none; any other status, such as the `403` private S3 and R2 buckets give for a missing object, makes `checkUpdate` throw;
- returns content directly, without `3xx` redirects, which the client does not follow;
- sends a `Content-Length` equal to the file size, or compresses with `Content-Encoding: gzip`;
- delivers the whole file within 2 minutes, never pausing for 15 seconds;
- serves a replaced file promptly: devices see a new patch or withdrawal only once the cache does.

## Advanced commands

You rarely need these.

| Command | Purpose |
|---|---|
| `baseline --action fetch\|verify\|release` | Download, verify or look up baselines in the baseline store, for investigation |

## Environment variables

| Variable | Purpose |
|---|---|
| `FLUTTER_PATCHER_KEYS` | A key bundle (`keys export --base64`) to sign with, typically a CI secret |
| `FLUTTER_PATCHER_SIGN_ROLE`, `FLUTTER_PATCHER_SIGN_PUBLIC_KEY` | Set for `signing.command`: always `patch`, and the public key to sign for |
| `FLUTTER_PATCHER_S3_ENDPOINT` | HTTPS endpoint of an S3-compatible service such as Cloudflare R2. Not needed for AWS S3 |
| `FLUTTER_PATCHER_BASELINE_TOKEN` | Access token for an HTTPS baseline store, sent as `Authorization: Bearer` |
| Standard AWS CLI variables and config | S3 credentials and region, such as `AWS_PROFILE` and `AWS_REGION` |
