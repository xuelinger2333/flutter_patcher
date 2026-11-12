# CLI Reference

**English** | [简体中文](cli-zh.md)

> Look up every flutter_patcher command: when to use it, how to use it, what it prints, and what to do when it fails.

This page is a reference: the first-run flow is in [Getting Started](getting-started.md), going live in the [Production Deployment Guide](production-playbook.md). Run every command from the project root:

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

Each command starts with its usage, followed by its options, output and error codes.

## init

Initializes the project. Run it once after adding the `flutter_patcher` dependency.

```bash
dart run flutter_patcher init
```

`init` is idempotent: existing files and keys are left as they are. It does three things:

1. **Creates `flutter_patcher.yaml`.** Every setting in it is commented out, so all defaults apply; see [Project settings](#project-settings-flutter_patcheryaml).
2. **Creates the project's patch key, with signing off.** The private key goes into this computer's key store, `~/.flutter_patcher/keys/<id>/keys.json`, readable by the current user only. The public key goes into `trust.patch`, together with `trust.enabled: false`. A host accepts only one key, so when `flutter_patcher.yaml` already names a key, for example in another checkout of the project, `init` creates none.
3. **Checks what `build` would refuse**: it warns about a `version` without a build number, or an Android or iOS project without exactly one application id.

Before you build a release, turn signing on and set `baseline_store` as in the [Production Deployment Guide](production-playbook.md), and back up the private key with `keys export --out <file>`.

**Options**

| Option | Description | Default |
|---|---|---|
| `--project <dir>` | The app's root; it must hold `pubspec.yaml` | The current directory |

**Output**: one JSON line on stdout.

| Field | Value |
|---|---|
| `command`, `status` | `init`, `initialized` |
| `config`, `config_created` | The path of `flutter_patcher.yaml`, and whether this `init` created it |
| `public_key` | The project's patch public key |
| `key_store` | Where the new private key was saved; only when this run created the key |
| `private_key` | Where `patch` and `publish` would take the private key from, as `keys status` reports it; `none` on a computer without it |
| `signing` | The value of `trust.enabled` |
| `notice` | What to do next: turn signing on, or `keys import` the private key on this computer |

Warnings print on stderr as `WARNING: <CODE>: <text>`, with the code `build` would fail with, such as `WARNING: BUILD_CONFIG_INVALID`. With warnings, `init` still exits with `0`.

**Errors**: exit code `2`, with `CODE: message` on stderr.

| Code | When | Fix |
|---|---|---|
| `CONFIG_INVALID` | The project directory has no `pubspec.yaml`, or `flutter_patcher.yaml` is invalid | Run it in the app's root, or correct what `message` names |
| `KEYS_ALREADY_CONFIGURED` | The project has no patch key and still has a pre-1.0 `flutter_patcher_keys/` directory | Run `keys import flutter_patcher_keys`, because released hosts accept only that key |

## build

Builds the app you release to the store, a host, and saves its baseline to the baseline store. Only release builds can receive patches, so `build` builds release mode only.

```bash
dart run flutter_patcher build android
dart run flutter_patcher build ios       # Apple Silicon Mac only
dart run flutter_patcher build android --dart-define=API_URL=https://api.example.com
dart run flutter_patcher build android -- --android-project-arg=store=play
```

**Common options**

| Option | Description | Default |
|---|---|---|
| `--flavor <name>` | Flutter flavor; 1 to 64 letters, digits and `_` | No flavor, recorded as `default` |
| `--version-code <n>` | The build number | The number after `+` in `version` in `pubspec.yaml` |
| `--dart-define <KEY=VALUE>`, `-D` | A define, read in Dart with `String.fromEnvironment` and the like; repeatable | None |
| `--dart-define-from-file <file>` | Defines from a JSON or `.env` file; repeatable, a later file wins over an earlier one and `--dart-define` wins over files | None |
| `--baseline-store <uri>` | Saves the baseline here | `baseline_store` in `flutter_patcher.yaml` |

**Other options**

| Option | Description | Default |
|---|---|---|
| `--strategy bytecode\|so` | Patch strategy, Android only; see [Two patch strategies](architecture.md#two-patch-strategies) | `bytecode` |
| `--channel <name>` | Channel, part of the host's identity and of its patch file name; 1 to 64 letters, digits and `_` | `production` |
| `--application-id <id>` | The application id (iOS bundle id) | Read from the Gradle or Xcode project; required when that names more than one |
| `--target <file>` | Entry file | `lib/main.dart` |
| `--out <dir>` | Output directory; it must not exist, so that a build never overwrites another | `.dart_tool/flutter_patcher/releases/<timestamp>/` |
| `--export-method <method>` | iOS only, passed to `flutter build ipa`: `app-store`, `ad-hoc`, `development` or `enterprise` | `app-store` |
| `--host-policy <file>` | A host policy you wrote; see [Custom Host Policy](advanced.md#custom-host-policy) | Derived from the project |
| `-- <options>` | Options after `--` are passed to `flutter build`; only [those listed below](#defines-and-flutter-build-options) | None |

**Output**: the output directory holds `app-release.apk` or `app-release.ipa` and the full report, `build.json`. stdout holds one JSON line:

| Field | Value |
|---|---|
| `command`, `status` | `build`, `build_archived` |
| `app` | Path of the APK or IPA to submit to the store |
| `application_id`, `version_code`, `strategy` | The host's identity |
| `signed` | `true` when the host accepts only files signed with the project's patch key |
| `fingerprint` | The fingerprint of this host build |
| `report` | Path of `build.json` |

**Warnings**: printed on stderr; the build completes as usual.

| Code | When | Fix |
|---|---|---|
| `UNSIGNED` | `flutter_patcher.yaml` has no patch key, or `trust.enabled` is `false` | Set `trust.enabled: true` (run `init` first if there is no key), then build again |
| `BASELINE_STORE_LOCAL` | The baseline is kept only in the project's `.flutter_patcher/baselines/` | Set `baseline_store`, or pass `--baseline-store` |

**Errors**: exit code `2`, with the JSON error on stderr.

| Code | When | Fix |
|---|---|---|
| `BASELINE_RELEASE_CONFLICT` | The same flavor and build number was built before with different content | Raise the build number, because a release has one baseline; identical content reuses the existing baseline |
| `BUILD_CONFIG_INVALID` | No build number in `pubspec.yaml`, no single application id, an invalid option, a define or an option after `--` that is not accepted, or `--out` exists | Correct what `message` names |
| `HOST_UNSUPPORTED` | `build ios` on a computer other than a Mac | Build on an Apple Silicon Mac |

### Defines and `flutter build` options

Daily development keeps using `flutter run` and `flutter build`. When you build a host, pass `build` the same `--dart-define` and `--dart-define-from-file`.

- Names and values are kept in the baseline as plain text, and every patch of the host is compiled with them. How a patch changes them is in [Defines in a patch](#defines-in-a-patch).
- `build` sets these defines itself, as `flutter build` does, and keeps them in the baseline: `FLUTTER_APP_FLAVOR` (`--flavor`), `FLUTTER_BUILD_NAME` (`version` before `+`), `FLUTTER_BUILD_NUMBER` (the build number), `FLUTTER_VERSION`, `FLUTTER_CHANNEL`, `FLUTTER_GIT_URL`, `FLUTTER_FRAMEWORK_REVISION`, `FLUTTER_ENGINE_REVISION`, `FLUTTER_DART_VERSION`, `FLUTTER_ENABLED_FEATURE_FLAGS`. Passing one of these names, or a define starting with `dart.`, fails with `BUILD_CONFIG_INVALID`.
- A host and its patches are built with the Flutter feature flags `windowing` and `accessibility_evaluations` off, whatever `flutter config` says.
- Only these options are accepted after `--`; any other fails with `BUILD_CONFIG_INVALID`. They are kept in the baseline, and an SO patch is rebuilt with them too.

| Option | `build android` | `build ios` |
|---|---|---|
| `--android-project-arg <key=value>` (`-P`) | ✓ | |
| `--android-project-cache-dir <dir>` | ✓ | |
| `--[no-]android-gradle-daemon` | ✓ | |
| `--[no-]android-skip-build-dependency-validation` | ✓ | |
| `--ignore-deprecation` | ✓ | |
| `--performance-measurement-file <file>` | ✓ | ✓ |
| `--[no-]fatal-warnings` | ✓ | ✓ |
| `--verbose` (`-v`) | ✓ | ✓ |

`flutter build ipa` does not support the first five, so `build ios` accepts only the last three.

## patch

Compares the current source with a released host's baseline and writes the host's patch file. With `--withdraw` it writes the host's withdrawal file instead and compiles nothing.

```bash
dart run flutter_patcher patch android
dart run flutter_patcher patch ios                  # On any supported computer
dart run flutter_patcher patch android --withdraw
dart run flutter_patcher patch android --dart-define=API_URL=https://api2.example.com
```

### Target host

`patch` finds the host's baseline by build number and flavor:

- Build number: the build number of `version` in `pubspec.yaml` by default; set it with `--version-code`.
- Flavor: `default` by default; set it with `--flavor`.

These keep the host's values and cannot be changed by `patch`, so it has no options for them and takes no `--`: the strategy, the channel, the patch key, the `FLUTTER_*` defines `build` sets itself, and the `flutter build` options. For example, after you change `version` in `pubspec.yaml`, `FLUTTER_BUILD_NAME` in the patch stays the same.

**Options**

| Option | Description | Default |
|---|---|---|
| `--version-code <n>` | The release to patch | The number after `+` in `version` in `pubspec.yaml` |
| `--flavor <name>` | The release's flavor | `default` |
| `--withdraw` | Writes a withdrawal file. It cannot be combined with `--target`, `--assets` or defines (`USAGE_ERROR`) | Off |
| `--dart-define <KEY=VALUE>`, `-D` | A define this patch changes or adds; repeatable | The host's defines |
| `--dart-define-from-file <file>` | The same, from a JSON or `.env` file | The host's defines |
| `--assets <key>` | Overrides only these asset keys; repeatable | Every changed asset |
| `--target <file>` | Entry file; it must be the one `build` used | The host's entry file |
| `--out <dir>` | Output directory; it must not exist | `.dart_tool/flutter_patcher/patches/<timestamp>/` |
| `--baseline-store <uri>` | Reads the baseline here | `baseline_store` in `flutter_patcher.yaml` |

### Defines in a patch

- A define you pass is one this patch changes or adds; every define you do not pass keeps the value the host was built with. A define cannot be removed.
- Every patch starts from the host's values, whatever earlier patches passed: to keep a value an earlier patch changed, pass it again.
- A changed define is part of its patch: when the patch is withdrawn, deleted by `rollback` or replaced by another patch, the values it changed go with it.
- Dart source must read a define you pass with `fromEnvironment` or `hasEnvironment`, or `patch` fails with `PATCH_DEFINE_UNREAD`. A patch can change defines and no source.

### Output

The output directory holds the patch file (named as in [Patch files](#patch-files)), the report `patch.json`, and `patch.draft`, the patch before sealing (not with `--withdraw`). stdout holds one JSON line; the field you need most is `file`:

| Field | Value |
|---|---|
| `command`, `status` | `patch`; `patch_created` or `withdrawal_created` |
| `file` | Full path of the patch file; this is the file you deliver. `null` when the host is signed and this machine has no private key for it; a `notice` then says what to do |
| `output` | The output directory |
| `seq`, `sealed_at` | The file's sequence, the Unix time in seconds it was sealed, and that time in UTC |
| `signed` | Whether the file is signed |
| `patch_key` | The host's patch public key, or `-` for an unsigned host |
| `platform`, `abi`, `strategy`, `fingerprint`, `scope` | The host the file is for |
| `changed`, `warnings` | For a patch only: what changed, and what to review |
| `defines` | Only when the patch changes or adds defines: their names, in `changed` and `added` |

> **Note**: for a signed host on a machine without its private key, `patch` still exits with `0`, with `"file":null`. Check `file` in scripts, or set `FLUTTER_PATCHER_KEYS` in CI.

**Warnings**: the patch is made, with these runtime limits; see [What can be patched](architecture.md#what-can-be-patched): `PATCH_NATIVE_ASSET_READER` (native code still reads the original assets), `PATCH_BACKGROUND_ENTRY` (a background entry point runs the original code), `PATCH_RESOURCE_SIZE` (patch assets stay in memory).

**Errors**: exit code `2`, with the JSON error on stderr; a rejected change adds `details`.

| Code | When | Fix |
|---|---|---|
| `BASELINE_NOT_FOUND` | No baseline for this flavor and build number | Pass the live release's `--version-code` and `--flavor`, and point `baseline_store` at the store `build` used |
| `PATCH_NO_CHANGES` | Nothing differs from the baseline | Save your edits; check the release you target |
| `PATCH_NATIVE_CHANGE` and other rejected changes | The change cannot be carried by a patch; see [What can be patched](architecture.md#what-can-be-patched) | Revert that part, or ship a store release |
| `PATCH_DEFINE_UNREAD` | No Dart source reads a define you passed | Check its name |
| `PATCH_BUILD_INPUTS_MISMATCH` | `--target` is not the host's entry file, or `pubspec.yaml` has a `version` and had none when the host was built | Drop `--target`; remove `version`, or release a new host |
| `PATCH_BASELINE_INCOMPATIBLE` | The host was built with flutter_patcher 1.0 or with another Flutter version | Patch 1.0 hosts with flutter_patcher 1.0.0+1; select the host's Flutter with `--flutter-sdk` |

## publish

Optional. Writes a `patch` output to the publication store (`store`). You do not need it when you deliver patch files yourself.

```bash
dart run flutter_patcher publish                     # Previews, asks, then writes
dart run flutter_patcher publish --yes               # Writes without asking
dart run flutter_patcher publish --withdraw          # Writes a withdrawal file
dart run flutter_patcher publish --patch <dir>       # Publishes a given patch output, for example to return to an earlier patch
```

**Sequence**: `publish` seals the file again with the publish time, so sequences rise in publish order and devices install a republished old patch too. It does not replace a file in the store whose sequence is equal or higher.

**Options**

| Option | Description | Default |
|---|---|---|
| `--yes`, `-y` | Publishes without asking | Asks in a terminal; previews without one |
| `--patch <dir>` | The `patch` output to publish. If it was deleted, check out that code and run `patch` again | The newest output under `.dart_tool/flutter_patcher/patches/` |
| `--withdraw` | Writes a withdrawal file for that output's host instead. An output of `patch --withdraw` is published as a withdrawal without this option | Off |
| `--seq <n>` | The file's sequence, from 1 to 4294967295; it must exceed the sequence of the file in the store | The current Unix time in seconds |
| `--key-file <file>` | Signs with this key bundle before any other source; see [Where the private key comes from](#where-the-private-key-comes-from) | |
| `--receipt <file>` | Also writes the result to this JSON file; the file must not exist. Written only for `published` | |

The confirmation prompt, `Publish <fileName> as <seq> to <store>? [y/N]`, prints on stderr. A file in a `file://` store reaches devices only after you upload it to `<url>/<fileName>`.

**Output**: stdout holds one JSON line with `command` (`publish`), `action` (`publish` or `withdraw`), `file` (the file name), `store`, `signed`, `seq` and `status`. All three `status` values exit with `0`, so check `status` in scripts:

| `status` | Meaning | Written? |
|---|---|---|
| `published` | The file is in the store | Yes |
| `already_published` | The store already holds this patch for this host (a withdrawal with `--withdraw`); `seq` is the stored one | No |
| `preview` | No `--yes`, and no terminal to ask in or the answer was not `y` | No |

**Errors**: exit code `2`, with `CODE: message` on stderr; nothing is written.

| Code | When | Fix |
|---|---|---|
| `KEYS_NOT_FOUND` | The host is signed and no source holds its private key | See [Where the private key comes from](#where-the-private-key-comes-from) |
| `PUBLISH_SEQUENCE_CONFLICT` | The store's file has a sequence at or above the new one, or `--seq` is out of range | Correct this computer's clock, or pass the `--seq` that `message` suggests |
| `PUBLISH_CONFLICT` | The store's file changed between reading and writing it | Run `publish` again |
| `PUBLISH_CONFIG_INVALID` | No patch output, an existing `--receipt` file, or a `store` with credentials | Run `patch` first or pass `--patch`; choose a new receipt file |
| `PUBLISH_STORE_UNAVAILABLE` | The AWS CLI is missing or failed | See [Publication store](#publication-store) |

## serve

Development only. Offers phones connected to this computer the newest file `patch` wrote for each host (a patch or a withdrawal file), exactly as written: it signs, numbers and stores nothing.

```bash
dart run flutter_patcher serve
```

- **Android**: every 2 seconds it runs `adb reverse` for newly connected devices, so the app on the phone reaches this computer. An app built without `url` checks `http://127.0.0.1:8686` by default.
- **iPhone**: it cannot reach this computer's `127.0.0.1`, so expose the port as an HTTPS address, for example with `cloudflared tunnel --url http://127.0.0.1:8686`, and pass that address to `checkUpdate(url: …)`.
- **Which files**: the file of each host's newest output under `.dart_tool/flutter_patcher/patches/`; a new `patch` output is picked up within about 2 seconds. Outputs written elsewhere with `patch --out` are not offered.
- **Who can reach it**: it listens on `127.0.0.1` only and answers only `GET /<fileName>`, with `Range` requests answered as `206`; anything else is `404`.

**Options**

| Option | Description | Default |
|---|---|---|
| `--port <port>` | The port on this computer, and the port `adb reverse` maps on Android devices. An app built without `url` checks `8686`, so with another port also run `adb reverse tcp:8686 tcp:<port>` | `8686` |

**Output**: nothing on stdout. Status lines print on stderr:

| Line | Meaning |
|---|---|
| `Android device <serial> reaches this computer at 127.0.0.1:<port>` | `adb reverse` is set up for that device |
| `Offering patch <seq> (<fileName>, signed\|unsigned)` | A host's newest output is a patch |
| `Offering a withdrawal of <fileName> (signed\|unsigned, <seq>)…` | A host's newest output is a withdrawal file |
| `Not offering <fileName>: …` | The newest output has no file, because the host is signed and its key is not on this machine. Nothing is offered for that host, not even an older file. Run `keys import` and `patch` again |
| `A device checked for updates` | A device read the file's header |
| `A device downloaded <fileName>` | A device read the whole file |

**Errors**: exit code `2` when it cannot start: `SERVE_PORT_BUSY` when the port is in use (choose another with `--port`), `USAGE_ERROR` for an invalid `--port`.

## keys

Moves and inspects the project's patch key, the Ed25519 key pair [`init`](#init) creates. The private key is kept outside the project, so use `keys` to take it to another computer or to sign in CI. Why to sign is in [Security model](architecture.md#security-model).

```bash
dart run flutter_patcher keys export --out <file>   # Writes the key to a file, for another machine
dart run flutter_patcher keys export --base64       # Prints the key as one line, for a CI secret
dart run flutter_patcher keys import <file>         # Adds a key to this machine's key store
dart run flutter_patcher keys status                # Shows where the private key would come from
```

**Subcommands and options**

| Subcommand and option | Description |
|---|---|
| `export --out <file>` | Writes this machine's copy of the project's key to a new file |
| `export --base64` | Prints it as one base64 line, the value of `FLUTTER_PATCHER_KEYS` |
| `import <file>` | Adds a key bundle to this machine's key store. `-` reads it from stdin; a directory reads the pre-1.0 `flutter_patcher_keys/` layout. In a project without a patch key, it also writes `trust.patch` and `trust.enabled: false` |
| `status` | Shows the public key, and which source the private key would be taken from to sign |
| `status --key-file <file>` | Also considers that key bundle, as the first source |

In CI you do not need `import`: set `FLUTTER_PATCHER_KEYS`; see [Keys in CI](advanced.md#keys-in-ci).

**Output**: one JSON line on stdout, with `command` `keys export`, `keys import` or `keys status`. The exception is `export --base64`, which prints only the base64 line. No command except `export` prints the private key.

| Subcommand | Fields |
|---|---|
| `export --out` | `status` (`keys_exported`), `file` |
| `import` | `status` (`keys_imported`), `key_store`, `public_key`, and `config` when it wrote `trust.patch` |
| `status` | `config`; `public_key` (`trust.patch`, or `null`); `private_key`: the source that would sign (`--key-file`, `FLUTTER_PATCHER_KEYS`, `signing.command`, `key store`) or `none`. `<source> (other key)` means that source holds another key; an error code means that source cannot be read |

**Errors**: exit code `2`, with `CODE: message` on stderr.

| Code | When | Fix |
|---|---|---|
| `KEYS_NOT_CONFIGURED` | `export` in a project without `trust.patch` | Run `init`, or `keys import` the project's bundle |
| `KEYS_NOT_FOUND` | `export` without the key in this machine's key store, or an `import` file that does not exist | Run it on the machine that has the key |
| `KEYS_MISMATCH` | `import` of a key other than the one `flutter_patcher.yaml` names | Use the project's key bundle |
| `KEYS_OUTPUT_EXISTS` | `--out` names an existing file | Choose a new file |
| `KEYS_BUNDLE_INVALID` | The file is not a key bundle, or holds no patch key | Use a file written by `keys export` |

### Where the private key comes from

`patch` and `publish` look for the private key in this order and sign with the first source that is present:

1. `--key-file <file>` (`publish` only): a key bundle file;
2. the `FLUTTER_PATCHER_KEYS` environment variable: the output of `keys export --base64`;
3. `signing.command` in `flutter_patcher.yaml`: a KMS or another signing service; see [Signing with a KMS or Signing Service](advanced.md#signing-with-a-kms-or-signing-service);
4. this machine's key store, including key directories written by flutter_patcher 1.0.

| Situation | Result |
|---|---|
| The first source present holds a key other than the host's | `KEYS_MISMATCH`. The next source is not tried, so that a wrong secret is reported instead of hidden |
| `signing.command` fails, times out or signs with another key | `SIGNER_COMMAND_FAILED` |
| No source is present | `patch` exits with `0` and `"file":null`; `publish` fails with `KEYS_NOT_FOUND` |

## doctor

Checks that the toolchain is ready. The first run downloads the engine and tools for your Flutter version and prepares them, which takes a few minutes; later runs are quick.

```bash
dart run flutter_patcher doctor
dart run flutter_patcher doctor --project . --baseline-store s3://my-bucket/baselines --version-code 7
```

By default it checks only the toolchain. Each of these options adds a check:

| Option | Also checks |
|---|---|
| `--project <dir>` | Where the project's private key comes from; on a Mac, also that `CFBundleVersion` in `ios/Runner/Info.plist` is `$(FLUTTER_BUILD_NUMBER)` or a positive integer |
| `--baseline-store <uri>` | That the baseline store is reachable. Write access is checked by `build` |
| `--version-code <n>`, `--flavor <name>` | With `--baseline-store`: that this release's baseline is complete |
| `--apk <file>` | That the APK's engine matches the selected Flutter version |
| `--json` | Changes no check: prints one JSON report instead of the checklist |

**Output**: stdout holds one line per check, `[passed|warning|not_run|failed] <id>: <message>`, then `Toolchain ready. …` or `Doctor failed.`. With `--json`, stdout holds one JSON object:

| Field | Value |
|---|---|
| `command`, `status` | `doctor`; `toolchain_ready` or `failed` |
| `checks` | One object per check: `id`, `status` (`passed`, `warning`, `not_run` or `failed`), `message`, and `code` for a failed check |
| `host`, `sdk`, `engine_build_id` | The computer, the Flutter SDK and the engine that were checked |
| `network_requests`, `elapsed_ms` | What the run cost |

**Exit codes**: `0` every check that ran passed; `1` a check failed, with `CODE: message` on stderr; `2` usage error. With `--offline` it uses only the local cache and fails when a required download is missing.

## Scripts and CI

### Output and exit codes

Every command follows the same convention: results go to stdout, warnings and progress to stderr. Branch on `code`, not on `message`: messages change between versions, codes do not. Every code is listed in [Troubleshooting](troubleshooting.md).

| Case | stdout | stderr | Exit code |
|---|---|---|---|
| Success | One line of JSON. Exceptions: `serve` prints nothing, `doctor` prints a checklist unless `--json` is given, `keys export --base64` prints the key bundle | Warnings and progress | `0` |
| `build`, `patch` or `baseline` fails | Nothing | One line of JSON with `command`, `status` (`failed`), `code` and `message`; `patch` adds `details` for a rejected change | `2` |
| Another command fails | Nothing | `CODE: message` | `2` |
| A `doctor` check fails | The checklist, or the JSON report | `CODE: message` | `1` |
| A command or option does not exist | Nothing | `USAGE_ERROR: message` | `2` |

Warnings print on stderr as `WARNING: <CODE>: <text>` and do not change the exit code.

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

## Reference

### Project settings: `flutter_patcher.yaml`

Every setting is optional, and none is secret, so the file can be committed. `init` creates it with every setting commented out; `keys import` also creates it in a project that has none.

| Setting | Meaning | Default |
|---|---|---|
| `trust.enabled` | `true`: hosts built from then on are signed hosts and accept only files signed with `trust.patch`. A file that names a key without `enabled`, as flutter_patcher 1.0 wrote, counts as `true` | `false`, as `init` writes it; `build` warns `UNSIGNED` |
| `trust.patch` | The base64 public key of the project's patch key, written by `init`. Do not edit it, because released hosts accept only the key they were built with. The `root` and `publisher` entries flutter_patcher 1.0 wrote are ignored | Not set until `init` runs |
| `baseline_store` | The baseline store, written by `build` and read by `patch`: `file://`, `s3://` or HTTPS | `.flutter_patcher/baselines/` in the project; `build` warns `BASELINE_STORE_LOCAL` |
| `url` | The default address of `checkUpdate()`. `build` writes it into the app, and `checkUpdate()` without `url` downloads `<url>/<fileName>`. An `https://` address, or `http://` to `127.0.0.1`, `localhost` or `::1` | `http://127.0.0.1:8686`, where `serve` offers patches |
| `store` | The publication store, where `publish` writes: `file://` or `s3://` | `.flutter_patcher/updates/` in the project |
| `signing.command` | An external program that signs; see [Where the private key comes from](#where-the-private-key-comes-from) | Not set |

An unknown setting, a value of the wrong type, or a `trust` without a valid `patch` fails with `CONFIG_INVALID`.

### Patch files

`patch` and `publish` write one kind of file, FPTC v1. A patch file and a withdrawal file have the same format and the same name.

**File name**: every file of a host has the same name, so a newer patch or a withdrawal replaces the previous file. On the device, `PatchTarget.fileName` gives the name.

| Host | File name | Example |
|---|---|---|
| Default flavor and channel (`default`, `production`) | `<version_code>-<abi>.fptc` | `7-arm64-v8a.fptc` |
| Any other flavor or channel | `<version_code>-<flavor>-<channel>-<abi>.fptc` | `7-paid-beta-arm64-v8a.fptc` |

Which files a device installs is in [What a device accepts](api-reference.md#what-a-device-accepts).

**File format**: a file is exactly 146 + L bytes, and at most 320 MiB.

| Offset | Bytes | Field |
|---|---|---|
| 0 | 4 | Magic `FPTC` (`0x46505443`) |
| 4 | 2 | Version `1` |
| 6 | 32 | Fingerprint of the host build |
| 38 | 4 | Sequence `seq`, uint32, at least 1; the Unix time in seconds when the file was sealed, or the value of `publish --seq` |
| 42 | 8 | Payload length L |
| 50 | 32 | SHA-256 of the payload |
| 82 | 64 | Ed25519 signature of bytes 0–81 followed by the payload; 64 zero bytes when unsigned |
| 146 | L | Payload: the patch ZIP. L = 0 is a withdrawal file |

### Directories

| Path | Contents | If it is lost |
|---|---|---|
| `~/.flutter_patcher/keys/<id>/keys.json` | This machine's copy of the private patch key, the key store | Hosts built with the key accept no new patch file, unless another copy exists (`keys export --out <file>`) |
| `.flutter_patcher/baselines/` | The default baseline store | The builds whose baselines it held can no longer be patched |
| `flutter_patcher.yaml` | Settings and the project's public key | `keys import` writes the key again |
| `.flutter_patcher/updates/` | The default publication store | Run `publish` again |
| `.dart_tool/flutter_patcher/patches/` | `patch` outputs; `serve` offers the newest file of each host | Run `patch` again |
| `.dart_tool/flutter_patcher/releases/` | `build` outputs | Nothing: the baseline is in the baseline store |
| `~/.flutter_patcher/` except `keys/` | Downloaded engines and tools, prepared Flutter SDK copies, the baseline cache | They are downloaded again |

### Storage requirements

#### Baseline store

Baselines are added and never replaced, so several build machines can share one baseline store.

| Type | Requirements |
|---|---|
| `s3://` | An installed and configured AWS CLI. The role needs read and write permissions and `s3:ListBucket`: without it a missing object answers `403` instead of `NoSuchKey`, and access fails with `BASELINE_STORE_UNREACHABLE`. For an S3-compatible service such as Cloudflare R2, set `FLUTTER_PATCHER_S3_ENDPOINT` |
| HTTPS | The root answers `200` to `HEAD`; `GET` is supported; `PUT` with `If-None-Match: *` answers `201` when created and `412` when the object exists; a missing object answers `404`. The access token goes in `FLUTTER_PATCHER_BASELINE_TOKEN` |
| `file://` | A local directory or a network mount |

#### Publication store

The store holds one file per host at its root, named as in [Patch files](#patch-files). A `file://` store also holds `.publish.lock`, which need not be uploaded or served.

| Type | Requirements |
|---|---|
| `s3://` | An AWS CLI with conditional writes (`put-object --if-match` and `--if-none-match`), permission to read and write objects under the prefix, and `s3:ListBucket`: without it a missing file reads as access denied and `publish` fails with `PUBLISH_STORE_UNAVAILABLE`. The address is a dedicated prefix under the bucket, such as `s3://my-bucket/my-app`; see [Publishing to S3](advanced.md#publishing-to-s3) |
| `file://` | A local directory or a network mount |

#### Download server

The HTTPS server or CDN that `checkUpdate` downloads from, whether `publish` or you put the file there, must:

- answer `GET <url>/<fileName>` with the file (`200`, or `206` for the requested range; range support is optional), and `404` when there is none. Any other status makes `checkUpdate` throw, including the `403` that private S3 and R2 buckets return for a missing object;
- return the content directly, because the client does not follow `3xx` redirects;
- send a `Content-Length` equal to the file size, or compress with `Content-Encoding: gzip`;
- deliver the whole file within 2 minutes, with no pause of 15 seconds or more;
- serve a replaced file promptly: every file of a host has the same name, so devices receive a new patch or withdrawal only once the cache serves it.

### Environment variables

| Variable | Purpose |
|---|---|
| `FLUTTER_PATCHER_KEYS` | A key bundle to sign with (the output of `keys export --base64`), typically a CI secret |
| `FLUTTER_PATCHER_S3_ENDPOINT` | The HTTPS endpoint of an S3-compatible service such as Cloudflare R2 |
| `FLUTTER_PATCHER_BASELINE_TOKEN` | The access token for an HTTPS baseline store, sent as `Authorization: Bearer` |
| Standard AWS CLI variables and configuration | S3 credentials and region, such as `AWS_PROFILE` and `AWS_REGION` |
| `FLUTTER_PATCHER_SIGN_ROLE`, `FLUTTER_PATCHER_SIGN_PUBLIC_KEY` | You do not set these: the CLI sets them to `patch` and the public key to sign for when it runs `signing.command` |

### Advanced commands

| Command | Purpose |
|---|---|
| `baseline --action fetch\|verify\|release` | Downloads, verifies or looks up baselines in the baseline store, for investigation |

### Removed in 1.1

These fail as unknown commands or options (`USAGE_ERROR`) on flutter_patcher 1.1.0 or newer. They still work in flutter_patcher 1.0.0+1, which patches hosts built with 1.0.0.

| Removed | Instead |
|---|---|
| `trust sign`, `trust publish` | None: the patch key is the only key |
| `publish --production --request <file>` | Delete or replace the `.fptc` file in the store yourself |
| `keys init` | `init`, which also creates `flutter_patcher.yaml`; signing is turned on with `trust.enabled` |
| `keys init --role`, `keys export --without-root`, `keys import --rotate` | None: the patch key is the only key |
