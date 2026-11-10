# CLI Reference

**English** | [简体中文](cli-zh.md)

> Look up every flutter_patcher command: its options, what it prints, its exit codes, its errors and warnings, and how it behaves in CI.

You are running the CLI by hand or from a script and need the exact behavior of a command. This page is a reference: the first-run flow is in [Getting Started](getting-started.md), going live in the [Production Deployment Guide](production-playbook.md). The CLI ships with the plugin, so run it in a project that depends on `flutter_patcher`:

```bash
dart run flutter_patcher <command> [options]
```

| Command | What it does |
|---|---|
| [`init`](#init) | Sets up a project once: creates `flutter_patcher.yaml` and the patch key, signing off |
| [`build`](#build) | Builds the app you release and records its baseline |
| [`patch`](#patch) | Makes the patch file of a released build; with `--withdraw`, a withdrawal file |
| [`publish`](#publish) | Optional: writes a patch file to a store, numbered at publish time |
| [`serve`](#serve) | Development only: offers the newest patch files to phones connected to this computer |
| [`keys`](#keys) | Moves the patch key to other computers and CI |
| [`doctor`](#doctor) | Checks and prepares the toolchain |

## Conventions

### Output and exit codes

| Case | stdout | stderr | Exit code |
|---|---|---|---|
| Success | One line of JSON. Exceptions: `serve` prints nothing, `doctor` prints a checklist unless `--json` is given, `keys export --base64` prints the key bundle | Warnings and progress | `0` |
| `build`, `patch` or `baseline` fails | Nothing | One line of JSON with `command`, `status` (`failed`), `code` and `message`; `patch` adds `details` for a rejected change | `2` |
| Another command fails | Nothing | `CODE: message` | `2` |
| A `doctor` check fails | The checklist, or the JSON report | `CODE: message` | `1` |
| A command or option does not exist | Nothing | `USAGE_ERROR: message` | `2` |

- Warnings print on stderr as `WARNING: <CODE>: <text>` and do not change the exit code.
- Branch on `code`, not on `message`: messages change between versions, codes do not. Every code is listed in [Troubleshooting](troubleshooting.md).

### Non-interactive use

- Only `publish` asks a question. Without a terminal and without `--yes` it writes nothing, prints `"status":"preview"` and exits with `0`, so pass `--yes` in CI.
- No other command reads from the terminal. A missing value falls back to its default or fails with an error code; nothing waits for input.
- Pass these explicitly in CI, because their defaults come from the checkout: `--version-code` when `pubspec.yaml` no longer holds the live release's build number, `--flavor` when the release has one, and `--application-id` when the project declares more than one application id.
- A signed host needs its private key on the runner: set `FLUTTER_PATCHER_KEYS`; see [Keys in CI](advanced.md#keys-in-ci).

### Options shared by commands

| Option | Commands | Description | Default |
|---|---|---|---|
| `--project <dir>` | All except `baseline` | The project directory | The current directory |
| `--flutter-sdk <path>` | `build`, `patch`, `doctor` | The Flutter SDK to use | Flutter on `PATH` |
| `--offline` | `build`, `patch`, `doctor` | Uses only verified local caches and no network; `patch --offline` also reads the baseline from the local cache only | Off |
| `--cache-dir <dir>` | `build`, `patch`, `doctor` | The cache directory; it must be under `~/.flutter_patcher` or the project's `.dart_tool/flutter_patcher` | `~/.flutter_patcher` |
| `-h`, `--help` | All | Prints the command's options | |
| `--version` | Top level | Prints `flutter_patcher <version>` | |

On Windows the cache path may be at most 80 characters, because deeper build trees exceed the Windows path limit. When `~/.flutter_patcher` is longer, pass a `--cache-dir` under the project's `.dart_tool/flutter_patcher`.

## Common workflows

Run each in the project root.

```bash
# Set up a project once, after flutter pub add flutter_patcher
dart run flutter_patcher init

# Try a change on an Android phone over USB
dart run flutter_patcher patch android
dart run flutter_patcher serve                      # Keep it running; it picks up each new patch

# Deliver a patch yourself: upload the file named in "file" to <url>/<fileName>, or hand it to your server
dart run flutter_patcher patch android

# Publish a patch to the store from CI
export FLUTTER_PATCHER_KEYS="<secret: the output of keys export --base64>"
dart run flutter_patcher patch android
dart run flutter_patcher publish --yes

# Return devices to the installed version
dart run flutter_patcher patch android --withdraw   # Deliver this file like a patch
dart run flutter_patcher publish --withdraw         # Or write the withdrawal file to the store

# Return devices to an earlier patch
dart run flutter_patcher publish --patch .dart_tool/flutter_patcher/patches/<dir>

# Patch an earlier live release, from a checkout of its source
dart run flutter_patcher patch android --version-code <its build number>

# Make an iOS patch on Linux or Windows
dart run flutter_patcher patch ios --baseline-store s3://my-bucket/baselines
```

What to check after each, and how to set up hosting, is in the [Production Deployment Guide](production-playbook.md).

## init

Prepares a project for flutter_patcher. Run it once in the app's root, after `flutter pub add flutter_patcher`.

```bash
dart run flutter_patcher init
```

| Option | Description | Default |
|---|---|---|
| `--project <dir>` | The app's root; it must hold `pubspec.yaml` | The current directory |

`init` does three things, and keeps whatever already exists:

1. Creates `flutter_patcher.yaml` with every setting commented out, so the defaults apply until you uncomment one; see [Project settings](#project-settings-flutter_patcheryaml).
2. Creates the project's patch key with signing off. The private key goes into this computer's key store, `~/.flutter_patcher/keys/<id>/keys.json`, readable by the current user only. The public key goes into `trust.patch`, next to `trust.enabled: false`. When `flutter_patcher.yaml` already names a key, for example in a clone of the project, `init` creates none, because a host accepts only one key.
3. Warns about what `build` would refuse: a `version` without a build number, or an Android or iOS project without exactly one application id.

**Output**: one JSON line on stdout:

| Field | Value |
|---|---|
| `command`, `status` | `init`, `initialized` |
| `config`, `config_created` | The path of `flutter_patcher.yaml`, and whether `init` created it |
| `public_key` | The project's patch public key |
| `key_store` | Where the new private key was saved; only when `init` created the key |
| `private_key` | Where `patch` and `publish` would take the private key from, as `keys status` reports it; `none` on a computer without it |
| `signing` | The value of `trust.enabled` |
| `notice` | What to do next: turn signing on before the build you ship, or `keys import` the private key on this computer |

Warnings print on stderr as `WARNING: <CODE>: <text>`, with the code `build` would fail with, such as `WARNING: BUILD_CONFIG_INVALID`.

**Exit codes**: `0` done, with or without warnings; `2` failed, with `CODE: message` on stderr.

| Code | When | Fix |
|---|---|---|
| `CONFIG_INVALID` | The project directory has no `pubspec.yaml`, or `flutter_patcher.yaml` is invalid | Run `init` in the app's root, or correct what `message` names |
| `KEYS_ALREADY_CONFIGURED` | The project names no key and still has a pre-1.0 `flutter_patcher_keys/` directory | Run `keys import flutter_patcher_keys`, because released hosts accept only that key |

**Non-interactive**: `init` never prompts, and running it again changes nothing that exists.

## build

Builds the release app, a host, and saves its baseline to the baseline store. `build` builds release mode only, because a patch is compiled for a release host.

```bash
dart run flutter_patcher build android
dart run flutter_patcher build ios       # Apple Silicon Mac only
```

| Option | Description | Default |
|---|---|---|
| `--strategy bytecode\|so` | Patch strategy, Android only; see [Two patch strategies](architecture.md#two-patch-strategies) | `bytecode` |
| `--flavor <name>` | Flutter flavor; 1 to 64 letters, digits and `_` | No flavor, recorded as `default` |
| `--channel <name>` | Channel, part of the host's identity and of its patch file name; 1 to 64 letters, digits and `_` | `production` |
| `--version-code <n>` | The build number | The number after `+` in `version` in `pubspec.yaml` |
| `--application-id <id>` | The application id (iOS bundle id) | Read from the Gradle or Xcode project; required when that names more than one |
| `--target <file>` | Entry file | `lib/main.dart` |
| `--out <dir>` | Output directory; it must not exist, so that a build never overwrites another | `.dart_tool/flutter_patcher/releases/<timestamp>/` |
| `--export-method <method>` | iOS only, passed to `flutter build ipa`: `app-store`, `ad-hoc`, `development` or `enterprise` | `app-store` |
| `--baseline-store <uri>` | Saves the baseline here | `baseline_store` in `flutter_patcher.yaml` |
| `--host-policy <file>` | A host policy you wrote; see [Custom Host Policy](advanced.md#custom-host-policy) | Derived from the project |

**Output**: the output directory holds `app-release.apk` or `app-release.ipa` and the full report, `build.json`. stdout holds one JSON line:

| Field | Value |
|---|---|
| `command`, `status` | `build`, `build_archived` |
| `app` | Path of the APK or IPA to release |
| `application_id`, `version_code`, `strategy` | The host's identity |
| `signed` | `true` when the host accepts only files signed with the project's patch key |
| `fingerprint` | The fingerprint of this host build |
| `report` | Path of `build.json` |

**Exit codes**: `0` built and baseline saved; `2` failed, with the JSON error on stderr.

| Code | When | Fix |
|---|---|---|
| `WARNING: UNSIGNED` | `flutter_patcher.yaml` names no patch key, or `trust.enabled` is `false` | Set `trust.enabled: true` (run `init` first if there is no key), then build again |
| `WARNING: BASELINE_STORE_LOCAL` | The baseline is kept only in the project's `.flutter_patcher/baselines/` | Set `baseline_store`, or pass `--baseline-store` |
| `BASELINE_RELEASE_CONFLICT` | The same flavor and build number was built before with different content | Raise the build number, because a release has one baseline; identical content reuses the existing baseline |
| `BUILD_CONFIG_INVALID` | No build number in `pubspec.yaml`, no single application id, an invalid option, or `--out` exists | Correct what `message` names |
| `HOST_UNSUPPORTED` | `build ios` on a computer other than a Mac | Build on an Apple Silicon Mac |

**Non-interactive**: `build` never prompts. Signing is decided here from `trust.enabled` and cannot be changed for a released host, so set it before the build you ship.

## patch

Compares the current source with a released build's baseline and writes the host's patch file. With `--withdraw` it writes a withdrawal file of the host instead and compiles nothing.

```bash
dart run flutter_patcher patch android
dart run flutter_patcher patch ios                  # On any supported computer
dart run flutter_patcher patch android --withdraw
```

| Option | Description | Default |
|---|---|---|
| `--version-code <n>` | The release to patch | The number after `+` in `version` in `pubspec.yaml` |
| `--flavor <name>` | The release's flavor | `default` |
| `--withdraw` | Writes a withdrawal file: devices that apply it delete their patch and run the installed version from the next cold start. It cannot be combined with `--target` or `--assets` (`USAGE_ERROR`) | Off |
| `--assets <key>` | Overrides only these asset keys; repeatable | Every changed asset |
| `--target <file>` | Entry file; it must be the one `build` used | `lib/main.dart` |
| `--out <dir>` | Output directory; it must not exist | `.dart_tool/flutter_patcher/patches/<timestamp>/` |
| `--baseline-store <uri>` | Reads the baseline here | `baseline_store` in `flutter_patcher.yaml` |

Strategy, channel and patch key come from the baseline, so `patch` has no options for them.

**Output**: the output directory holds `patch.json` (the report), `patch.draft` (the patch before sealing; not with `--withdraw`) and the patch file, named as in [Patch files](#patch-files). stdout holds one JSON line:

| Field | Value |
|---|---|
| `command`, `status` | `patch`; `patch_created` or `withdrawal_created` |
| `output` | The output directory |
| `file` | Full path of the patch file. `null` when the host is signed and this machine has no private key for it; a `notice` then says what to do |
| `seq`, `sealed_at` | The file's sequence, the Unix time in seconds it was sealed, and that time in UTC |
| `signed` | Whether the file is signed |
| `patch_key` | The host's patch public key, or `-` for an unsigned host |
| `platform`, `abi`, `strategy`, `fingerprint`, `scope` | The host the file is for |
| `changed`, `warnings` | For a patch: what changed, and what to review |

**Exit codes**: `0` file written, or draft written with `"file":null`; `2` failed, with the JSON error on stderr.

| Code | When | Fix |
|---|---|---|
| `BASELINE_NOT_FOUND` | No baseline for this flavor and build number | Pass the live release's `--version-code` and `--flavor`, and point `baseline_store` at the store `build` used |
| `PATCH_NO_CHANGES` | Nothing differs from the baseline | Save your edits; check the release you target |
| `PATCH_NATIVE_CHANGE` and other rejected changes | The change cannot be carried by a patch; see [What can be patched](architecture.md#what-can-be-patched) | Revert that part, or ship a store release |
| `PATCH_BASELINE_INCOMPATIBLE` | The host was built with flutter_patcher 1.0 or with another Flutter version | Patch 1.0 hosts with flutter_patcher 1.0.0+1; select the release's Flutter with `--flutter-sdk` |
| `WARNING: PATCH_NATIVE_ASSET_READER`, `PATCH_BACKGROUND_ENTRY`, `PATCH_RESOURCE_SIZE` | The patch is made, and part of it does not take effect everywhere | Read the warning; see [Troubleshooting](troubleshooting.md) |

**Non-interactive**: `patch` never prompts. On a runner without the key of a signed host it still exits with `0` and `"file":null`, so check `file` in scripts, or set `FLUTTER_PATCHER_KEYS`.

## publish

Optional. Seals a `patch` output again with a sequence numbered at publish time, so that files are ordered by when you publish them, and writes it to the publication store as `<fileName>`. It replaces the file in the store only with a higher sequence, because devices install only a file numbered above every file they accepted.

```bash
dart run flutter_patcher publish         # Previews, asks, then writes
dart run flutter_patcher publish --yes   # Writes without asking
```

| Option | Description | Default |
|---|---|---|
| `--patch <dir>` | The `patch` output to publish. If it was deleted, check out that code and run `patch` again | The newest output under `.dart_tool/flutter_patcher/patches/` |
| `--withdraw` | Writes a withdrawal file for that output's host instead. An output of `patch --withdraw` is published as a withdrawal without this option | Off |
| `--yes`, `-y` | Publishes without asking | Asks in a terminal; previews without one |
| `--seq <n>` | The file's sequence, from 1 to 4294967295; it must exceed the sequence of the file in the store | The current Unix time in seconds |
| `--key-file <file>` | Signs with this key bundle before any other source | |
| `--receipt <file>` | Also writes the result to this JSON file; the file must not exist. Written only for `published` | |

**Output**: stdout holds one JSON line with `command` (`publish`), `action` (`publish` or `withdraw`), `file` (the file name), `store`, `signed`, `seq` and `status`:

| `status` | Meaning | Written? |
|---|---|---|
| `published` | The file is in the store | Yes |
| `already_published` | The store already holds this patch for this host, or a withdrawal with `--withdraw`; `seq` is the stored one | No |
| `preview` | No `--yes`, and no terminal to ask in or the answer was not `y` | No |

The question, `Publish <fileName> as <seq> to <store>? [y/N]`, prints on stderr. With a `file://` store and `url` set, stderr also says where to upload the file, because devices see it only once `<url>/<fileName>` serves it.

**Exit codes**: `0` for every `status` above, including `preview`; `2` failed, with `CODE: message` on stderr and nothing written.

| Code | When | Fix |
|---|---|---|
| `KEYS_NOT_FOUND` | The host is signed and no source holds its private key | See [Where the private key comes from](#where-the-private-key-comes-from) |
| `PUBLISH_SEQUENCE_CONFLICT` | The store's file has a sequence at or above the new one, or `--seq` is out of range | Correct this computer's clock, or pass the `--seq` that `message` suggests |
| `PUBLISH_CONFLICT` | The store's file changed between reading and writing it | Run `publish` again |
| `PUBLISH_CONFIG_INVALID` | No patch output, an existing `--receipt` file, or a `store` with credentials | Run `patch` first or pass `--patch`; choose a new receipt file |
| `PUBLISH_STORE_UNAVAILABLE` | The AWS CLI is missing or failed | See [Publication store](#publication-store) |

**Non-interactive**: pass `--yes`. Without it and without a terminal, `publish` exits with `0` and `"status":"preview"`, so check `status` in scripts.

## serve

Development only. Offers the newest file `patch` wrote for each host, a patch or a withdrawal file, exactly as written. It signs, numbers and stores nothing.

```bash
dart run flutter_patcher serve
```

| Option | Description | Default |
|---|---|---|
| `--port <port>` | The port on this computer, and the port `adb reverse` maps on Android devices. An app built without `url` checks `8686`, so with another port also run `adb reverse tcp:8686 tcp:<port>` | `8686` |

- It offers the file of each host's newest output under `.dart_tool/flutter_patcher/patches/`, and picks up a new `patch` run within about 2 seconds. Outputs written elsewhere with `patch --out` are not offered.
- Every 2 seconds it runs `adb reverse` for newly connected Android devices.
- It listens on `127.0.0.1` only and answers only `GET /<fileName>`, with `Range` requests answered as `206`; anything else is `404`.
- An iPhone cannot reach this computer's `127.0.0.1`, so expose the port over HTTPS, for example with `cloudflared tunnel --url http://127.0.0.1:8686`, and pass that address to `checkUpdate(url: …)`.

**Output**: nothing on stdout. Status lines print on stderr:

| Line | Meaning |
|---|---|
| `Android device <serial> reaches this computer at 127.0.0.1:<port>` | `adb reverse` is set up for that device |
| `Offering patch <seq> (<fileName>, signed\|unsigned)` | A host's newest output is a patch |
| `Offering a withdrawal of <fileName> (signed\|unsigned, <seq>)…` | A host's newest output is a withdrawal file |
| `Not offering <fileName>: …` | The newest output has no file, because the host is signed and its key is not on this machine. Nothing is offered for that host, not even an older file. Run `keys import` and `patch` again |
| `A device checked for updates` | A device read the file's header |
| `A device downloaded <fileName>` | A device read the whole file |

**Exit codes**: `serve` runs until Ctrl+C. `2` when it cannot start: `SERVE_PORT_BUSY` when the port is in use (choose another with `--port`), `USAGE_ERROR` for an invalid `--port`.

**Non-interactive**: `serve` never prompts and never exits by itself, so do not run it in CI.

## keys

Moves and inspects the project's patch key, the Ed25519 key pair [`init`](#init) creates. A host built while `trust.enabled` in `flutter_patcher.yaml` is `true` installs only files signed with it; why to sign is in [Security model](architecture.md#security-model). The private key stays outside the project.

```bash
dart run flutter_patcher keys export --out <file>   # Writes the key to a file, for another machine
dart run flutter_patcher keys export --base64       # Prints the key as one line, for a CI secret
dart run flutter_patcher keys import <file>         # Adds a key to this machine's key store
dart run flutter_patcher keys status                # Shows where the private key would come from
```

| Subcommand and option | Description |
|---|---|
| `export --out <file>` | Writes this machine's copy of the project's key to a new file |
| `export --base64` | Prints it as one base64 line, the value of `FLUTTER_PATCHER_KEYS` |
| `import <file>` | Adds a key bundle to the key store. `-` reads it from stdin; a directory reads the pre-1.0 `flutter_patcher_keys/` layout. In a project without a patch key, it also writes `trust.patch`, with `trust.enabled: false` |
| `status --key-file <file>` | Also considers that key bundle, as the first source |

**Output**: one JSON line on stdout with `command` (`keys export`, `keys import` or `keys status`). `export --base64` prints only the base64 line. No command prints the private key except `export`.

| Subcommand | Fields |
|---|---|
| `export --out` | `status` (`keys_exported`), `file` |
| `import` | `status` (`keys_imported`), `key_store`, `public_key`, and `config` when it wrote `trust.patch` |
| `status` | `config`; `public_key` (`trust.patch`, or `null`); `private_key`: the source that would sign (`--key-file`, `FLUTTER_PATCHER_KEYS`, `signing.command`, `key store`) or `none`. `<source> (other key)` means that source holds another key; an error code means that source cannot be read |

**Exit codes**: `0` done; `2` failed, with `CODE: message` on stderr.

| Code | When | Fix |
|---|---|---|
| `KEYS_NOT_CONFIGURED` | `export` in a project without `trust.patch` | Run `init`, or `keys import` the project's bundle |
| `KEYS_NOT_FOUND` | `export` without the key in this machine's key store, or an `import` file that does not exist | Run it on the machine that has the key |
| `KEYS_MISMATCH` | `import` of a key other than the one `flutter_patcher.yaml` names | Use the project's key bundle |
| `KEYS_OUTPUT_EXISTS` | `--out` names an existing file | Choose a new file |
| `KEYS_BUNDLE_INVALID` | The file is not a key bundle, or holds no patch key | Use a file written by `keys export` |

**Non-interactive**: `keys` never prompts. In CI, set `FLUTTER_PATCHER_KEYS` instead of importing; see [Keys in CI](advanced.md#keys-in-ci).

> **Warning: keep a copy of the private key**
> A released host accepts only the key it was built with, and the key cannot be replaced. If every copy is lost, those hosts accept no new patch file: delete `trust:` from `flutter_patcher.yaml`, run `init` to create a new key, set `trust.enabled: true`, and ship a new store release.

### Where the private key comes from

`patch` and `publish` sign with the first source that is present:

1. `--key-file <file>` (`publish` only): a key bundle file;
2. the `FLUTTER_PATCHER_KEYS` environment variable: a key bundle, as `keys export --base64` prints it;
3. `signing.command` in `flutter_patcher.yaml`: a KMS or another signing service; see [Signing with a KMS or Signing Service](advanced.md#signing-with-a-kms-or-signing-service);
4. this machine's key store, including key directories written by flutter_patcher 1.0.

| Situation | Result |
|---|---|
| The first source present holds a key other than the host's | `KEYS_MISMATCH`; the next source is not tried, so that a wrong secret is reported instead of hidden |
| `signing.command` fails, times out or signs with another key | `SIGNER_COMMAND_FAILED` |
| No source is present | `patch` exits with `0` and `"file":null`; `publish` fails with `KEYS_NOT_FOUND` |

## doctor

Checks that the toolchain is ready. The first run downloads the engine and tools for your Flutter version and prepares them, which takes a few minutes.

```bash
dart run flutter_patcher doctor
```

| Option | Description | Default |
|---|---|---|
| `--json` | Prints one JSON report instead of the checklist | Checklist |
| `--project <dir>` | Also reports where the project's private key comes from; on a Mac, also checks that `CFBundleVersion` in `ios/Runner/Info.plist` is `$(FLUTTER_BUILD_NUMBER)` or a positive integer | Not checked |
| `--baseline-store <uri>` | Also checks that the baseline store is reachable. Write access is checked by `build` | Not checked |
| `--version-code <n>` `--flavor <name>` | With `--baseline-store`: also checks that this release's baseline is complete | Not checked |
| `--apk <file>` | Also checks that the APK's engine matches the selected Flutter version | Not checked |

**Output**: stdout holds one line per check, `[passed|warning|not_run|failed] <id>: <message>`, then `Toolchain ready. …` or `Doctor failed.`. With `--json`, stdout holds one JSON object:

| Field | Value |
|---|---|
| `command`, `status` | `doctor`; `toolchain_ready` or `failed` |
| `checks` | One object per check: `id`, `status` (`passed`, `warning`, `not_run` or `failed`), `message`, and `code` for a failed check |
| `host`, `sdk`, `engine_build_id` | The computer, the Flutter SDK and the engine that were checked |
| `network_requests`, `elapsed_ms` | What the run cost |

**Exit codes**: `0` every check that ran passed; `1` a check failed, with `CODE: message` on stderr; `2` usage error.

**Non-interactive**: `doctor` never prompts. With `--offline` it uses only the local cache and fails when a required download is missing.

## Patch files

`patch` and `publish` write one kind of file, FPTC v1. A patch file and a withdrawal file have the same format and the same name.

These files need flutter_patcher 1.1.0 or newer. Hosts built with flutter_patcher 1.0.0 are patched with flutter_patcher 1.0.0+1; see [Upgrading from 1.0](upgrading.md).

| Host | File name | Example |
|---|---|---|
| Default flavor and channel (`default`, `production`) | `<version_code>-<abi>.fptc` | `7-arm64-v8a.fptc` |
| Any other flavor or channel | `<version_code>-<flavor>-<channel>-<abi>.fptc` | `7-paid-beta-arm64-v8a.fptc` |

Every file of a host has the same name, so a newer patch or a withdrawal replaces the previous file. On the device, `PatchTarget.fileName` gives the name.

| Offset | Bytes | Field |
|---|---|---|
| 0 | 4 | Magic `FPTC` (`0x46505443`) |
| 4 | 2 | Version `1` |
| 6 | 32 | Fingerprint of the host build |
| 38 | 4 | Sequence `seq`, uint32, at least 1 |
| 42 | 8 | Payload length L |
| 50 | 32 | SHA-256 of the payload |
| 82 | 64 | Ed25519 signature of bytes 0–81 followed by the payload; 64 zero bytes when unsigned |
| 146 | L | Payload: the patch ZIP. L = 0 is a withdrawal file |

- A file is exactly 146 + L bytes, and at most 320 MiB.
- `seq` is the Unix time in seconds when the file was sealed, or the value of `publish --seq`.
- Which files a device installs: [What a device accepts](api-reference.md#what-a-device-accepts).

## Project settings: `flutter_patcher.yaml`

Every setting is optional, and none is secret. `init` creates the file with every setting commented out; `keys import` also creates it in a project that has none.

| Setting | Meaning | Default |
|---|---|---|
| `url` | Optional: the default address of `checkUpdate()`. `build` writes it into the app, and `checkUpdate()` without `url` downloads `<url>/<fileName>` from it. An `https://` address, or `http://` to `127.0.0.1`, `localhost` or `::1` | `http://127.0.0.1:8686`, where `serve` offers patches |
| `store` | The publication store, where `publish` writes: `file://` or `s3://` | `.flutter_patcher/updates/` in the project |
| `baseline_store` | The baseline store, written by `build` and read by `patch`: `file://`, `s3://` or HTTPS | `.flutter_patcher/baselines/` in the project; `build` warns `BASELINE_STORE_LOCAL` |
| `trust.patch` | The base64 public key of the project's patch key, written by `init`. Do not edit it, because released hosts accept only the key they were built with. The `root` and `publisher` entries flutter_patcher 1.0 wrote are ignored | Not set until `init` runs |
| `trust.enabled` | `true`: hosts built from then on are signed and accept only files signed with `trust.patch`. A file that names a key without `enabled`, as flutter_patcher 1.0 wrote, counts as `true` | `false`, as `init` writes it; `build` warns `UNSIGNED` |
| `signing.command` | An external program that signs; see [Where the private key comes from](#where-the-private-key-comes-from) | Not set |

An unknown setting, a value of the wrong type, or a `trust` without a valid `patch` fails with `CONFIG_INVALID`.

## Directories

| Path | Contents | If it is lost |
|---|---|---|
| `flutter_patcher.yaml` | Settings and the project's public key | `keys import` writes the key again |
| `~/.flutter_patcher/keys/<id>/keys.json` | This machine's copy of the private patch key, the key store | Hosts built with the key accept no new patch file, unless another copy exists (`keys export --out <file>`) |
| `.flutter_patcher/baselines/` | The default baseline store | The builds whose baselines it held can no longer be patched |
| `.flutter_patcher/updates/` | The default publication store | Run `publish` again |
| `.dart_tool/flutter_patcher/releases/` | `build` outputs | Nothing: the baseline is in the baseline store |
| `.dart_tool/flutter_patcher/patches/` | `patch` outputs; `serve` offers the newest file of each host | Run `patch` again |
| `~/.flutter_patcher/` except `keys/` | Downloaded engines and tools, prepared Flutter SDK copies, the baseline cache | They are downloaded again |

## Storage requirements

### Baseline store

| Type | Requirements |
|---|---|
| `s3://` | An installed and configured AWS CLI. The role needs read and write permissions and `s3:ListBucket`, because without it a missing object answers `403` instead of `NoSuchKey` and access fails with `BASELINE_STORE_UNREACHABLE`. For an S3-compatible service such as Cloudflare R2, set `FLUTTER_PATCHER_S3_ENDPOINT` |
| HTTPS | The root answers `200` to `HEAD`; `GET` is supported; `PUT` with `If-None-Match: *` answers `201` when created and `412` when the object exists; a missing object answers `404`. The access token goes in `FLUTTER_PATCHER_BASELINE_TOKEN` |
| `file://` | A local directory or a network mount |

Baselines are added and never replaced, so several build machines can share one baseline store.

### Publication store

| Type | Requirements |
|---|---|
| `s3://` | An AWS CLI with conditional writes (`put-object --if-match` and `--if-none-match`), permission to get and put objects under the prefix, and `s3:ListBucket`, because without it a missing file reads as access denied and `publish` fails with `PUBLISH_STORE_UNAVAILABLE`. The address is a dedicated prefix under the bucket, such as `s3://my-bucket/my-app`; see [Publishing to S3](advanced.md#publishing-to-s3) |
| `file://` | A local directory or a network mount |

The store holds one file per host at its root, named as in [Patch files](#patch-files). A `file://` store also holds `.publish.lock`, which need not be uploaded or served.

### Download server

The HTTPS server or CDN that `checkUpdate` downloads from, whether `publish` or you put the file there, must:

- answer `GET <url>/<fileName>` with the file (`200`, or `206` for the requested range; range support is optional), and `404` when there is none. Any other status makes `checkUpdate` throw, including the `403` that private S3 and R2 buckets return for a missing object;
- return the content directly, because the client does not follow `3xx` redirects;
- send a `Content-Length` equal to the file size, or compress with `Content-Encoding: gzip`;
- deliver the whole file within 2 minutes, with no pause of 15 seconds or more;
- serve a replaced file promptly, because every file of a host has the same name: devices receive a new patch or withdrawal only once the cache serves it.

## Advanced commands

| Command | Purpose |
|---|---|
| `baseline --action fetch\|verify\|release` | Downloads, verifies or looks up baselines in the baseline store, for investigation |

## Environment variables

| Variable | Purpose |
|---|---|
| `FLUTTER_PATCHER_KEYS` | A key bundle (`keys export --base64`) to sign with, typically a CI secret |
| `FLUTTER_PATCHER_SIGN_ROLE`, `FLUTTER_PATCHER_SIGN_PUBLIC_KEY` | Set by the CLI for `signing.command`: `patch`, and the public key to sign for |
| `FLUTTER_PATCHER_S3_ENDPOINT` | The HTTPS endpoint of an S3-compatible service such as Cloudflare R2 |
| `FLUTTER_PATCHER_BASELINE_TOKEN` | The access token for an HTTPS baseline store, sent as `Authorization: Bearer` |
| Standard AWS CLI variables and configuration | S3 credentials and region, such as `AWS_PROFILE` and `AWS_REGION` |

## Removed in 1.1

These fail as unknown commands or options (`USAGE_ERROR`) on flutter_patcher 1.1.0 or newer. They still work in flutter_patcher 1.0.0+1, which patches hosts built with 1.0.0.

| Removed | Instead |
|---|---|
| `trust sign`, `trust publish` | None: the patch key is the only key |
| `publish --production --request <file>` | Delete or replace the `.fptc` file in the store yourself |
| `keys init` | `init`, which also creates `flutter_patcher.yaml`; signing is turned on with `trust.enabled` |
| `keys init --role`, `keys export --without-root`, `keys import --rotate` | None: the patch key is the only key |
