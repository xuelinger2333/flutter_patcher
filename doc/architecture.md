# How It Works

**English** | [简体中文](architecture-zh.md)

> Understand what a host is, how a patch is built against its baseline, how a device decides to install a patch file, and which changes a patch can carry.

You have run a first patch or are deciding whether flutter_patcher fits your app. This page explains the mechanism and its limits; it does not list commands and options, which are in the [CLI Reference](cli.md), or the Dart API, which is in the [API Reference](api-reference.md).

## Three roles

```text
  Your computer (CLI)              Delivery                            User's device (plugin)
 ─────────────────────           ─────────────────────────────       ──────────────────────
 build  → host + baseline                                            runs the host build produced
 patch  → one .fptc file  ──→    an HTTPS host, your own API,   ──→  checkUpdate / applyPatch
 publish → .fptc in a store       a push message, a bundled file      or applyPatchBytes / applyPatchFile
                                                                             │
                                                          verifies, installs; loads at the next cold start
```

| Role | What it does |
|---|---|
| Your computer | `dart run flutter_patcher build` makes the host app and its baseline. `patch` turns each later change into one patch file, such as `1-arm64-v8a.fptc`. The optional `publish` writes that file to a store (a directory or S3); `serve` offers it to development devices |
| Delivery | The built-in downloader (`checkUpdate` and `applyPatch`) fetches the file from a URL. An app can also obtain the file through its own channel and pass it to `applyPatchBytes` or `applyPatchFile`; see [Custom delivery](advanced.md#custom-delivery-from-your-own-server) |
| Device | Native code verifies the file, installs it, and loads it at the next cold start |

The **baseline store** keeps the build record of every released version. Only the CLI reads it.

## The host: an app that accepts patches

Patches install only on apps built with `flutter_patcher build`, called **hosts**, because a plain `flutter build` has nothing that loads a patch. Compared with a plain build, a host contains:

1. **The flutter_patcher engine**: the official Flutter engine with the additions patch loading needs. The CLI downloads and verifies it for your Flutter version.
2. **A generated entry point** that runs before your `main` and loads the installed patch.
3. **The host policy**: the identity of the build and its optional patch public key.

| Host policy field | Content |
|---|---|
| `application_id`, `version_code` | Application id (iOS bundle id) and build number |
| `flavor`, `channel` | Default `default` and `production` |
| `abi` | `arm64-v8a` or `ios-arm64` |
| `strategy` | `bytecode` or `so` |
| `fptc_key` | The patch public key, or `-` for an unsigned host |

`build` writes the policy, together with the compile fingerprint, into the app package (`assets/flutter_patcher/host-trust.json` in the APK, or Info.plist on iOS). The device judges every patch file by this policy. Because the policy is part of the released package, a host keeps the signing mode and key it was built with, so a key added later applies only to hosts built after it.

On Android, a host applies patches on Android 9 (API 28) and later, in the app's main process. On older versions the app runs as built, because the host refuses to load patches there.

## Two patch strategies

A Flutter release app compiles your Dart code to machine code. flutter_patcher can update it in two ways:

| | Bytecode (default) | SO |
|---|---|---|
| A patch contains | Selected libraries and required callers/parts compiled to bytecode, with package fallbacks when host reuse fails | A whole recompiled `libapp.so` |
| How it runs | An interpreter in the engine runs all the code the patch carries; Flutter, plugins and the packages the patch does not carry still run as the app's machine code | At startup, Flutter loads the patch's `libapp.so` instead of the app's |
| Platforms | Android, iOS | Android only |
| Patch size | Small: your app's code, without Flutter and plugins | Large: about the size of `libapp.so` |
| Speed of the patched code | Everything the patch carries is interpreted, slower than machine code | Same as the original |

iOS hosts use bytecode because iOS does not allow loading downloaded machine code. On Android the strategy is chosen at build time (`build android --strategy so` for SO), and every patch of that release uses it, because the host can load only the kind it was built for.

`patch` chooses between two tiers of bytecode patch:

- **lean** carries selected application libraries;
- **whole** also carries selected libraries from pure-Dart dependencies.

Source hashes and define readers seed selection. Callers, export barrels and parts are included when they must refer to a changed library; newly reached libraries absent from the host are included too. Other imports initially keep their original host URIs.

The released host can supply only APIs retained in its interface. If a patch first calls an existing function, constructor or getter that the host did not retain, the CLI uses the reported call sites to include their imports and re-exported libraries, then retries. Allocation diagnostics can identify an owning library directly. These expansions are conservative and can include other libraries visible at the same call site. After at most three expansions, or when diagnostics cannot guide them, compilation falls back to carrying the application package and then all free dependencies, as the package-based compiler does. Native and pinned packages always stay in the host; interface, allocation, inherited-member and FFI checks still apply to every attempt.

Selection works at library granularity, not individual functions or changed lines. Barrel imports and cycles commonly expand the selection substantially, and fallbacks can carry the whole application and its free dependencies. More carried code means larger patches and more interpreted code at runtime. Host interface generation keeps its existing scope; this optimization does not retain all application-internal calls or require rebuilding an otherwise compatible shipped host. `selected_sources`, `carried_packages` and `selection` (`libraries`, `application` or `whole`) record the final scope in `patch.json`; compiler reports record each attempt.

A resource-only patch reuses host main and emits only its generated module entry. Resource and font collection is independent of source selection.

## Baselines: what a patch is compared with

A patch is the difference between your current code and the version on the user's phone, so the CLI must know that version exactly. Alongside the app, `build` saves its complete record as a **baseline**: compiled output, source hashes, dependencies, assets, the host policy, and the versions of the engine and tools it used.

`patch` finds the baseline by flavor and build number (Android versionCode, iOS CFBundleVersion), compares your current source with it, and packs only what changed.

| Rule | Effect |
|---|---|
| Baselines are added, never replaced | If the same build number builds to different content, `build` fails with `BASELINE_RELEASE_CONFLICT`, because released apps would no longer match their baseline. To ship new content, raise the build number |
| Tools stay fixed | Every patch of a release uses the engine and tool versions its baseline records, so released apps can still be patched after flutter_patcher ships a newer engine |

A release whose baseline is lost can no longer be patched, because nothing records what its users run; those users need a new store release. Keeping baselines is covered in [Keep the Baselines](production-playbook.md#2-keep-the-baselines).

## The patch file

A patch file (FPTC v1) is a 146-byte header followed by the payload, a ZIP of the patch. Patch files need flutter_patcher 1.1.0 or newer; hosts built with flutter_patcher 1.0.0 are patched with flutter_patcher 1.0.0+1, see [Upgrading from 1.0](upgrading.md). The byte layout and naming rules are in [Patch files](cli.md#patch-files).

| Header field | Purpose |
|---|---|
| Host fingerprint | The one host build the file is for |
| Sequence (`seq`) | The Unix time in seconds when the file was sealed, unless `publish --seq` sets one. A device accepts only files numbered above every file it has accepted |
| Payload SHA-256 | Detects a damaged or altered payload |
| Ed25519 signature | Proves the file was signed with the patch key; zero bytes when unsigned |

- A file with an empty payload is a **withdrawal**: a device that applies it removes its patch.
- Each host build has one file name, such as `7-arm64-v8a.fptc`, so a newer patch or a withdrawal replaces the previous file. On the device, `FlutterPatcher.patchTarget` gives the same name as `fileName`.
- A file is at most 320 MiB.

## Security model

Signing uses one key, the **patch key**. With it, storage, CDNs, the transport and the app's way of fetching need not be trusted, because an altered file fails verification.

| Host | Which files it installs |
|---|---|
| Signed (built while `trust.enabled` in `flutter_patcher.yaml` is `true`) | Only files signed with that key |
| Unsigned (`build` prints `WARNING: UNSIGNED`) | Any intact file for the host, signed or not. Whoever can hand the app a file can run code in it, so the delivery channel must be trusted. The built-in downloader accepts only HTTPS, or plain HTTP to the device itself for `serve`; with custom delivery, securing the channel is the app's responsibility |

How to turn signing on before the build you ship is in [Turn On Signing](production-playbook.md#3-turn-on-signing). The private key stays outside the project: `patch` and `publish` take it from a key bundle, an environment variable, a signing command or the key store on your computer, see [Where the private key comes from](cli.md#where-the-private-key-comes-from). `build` needs only the public key.

> **Warning: a released host's key cannot be replaced**
>
> If the private key is lost, hosts built with it accept no new patch file. If it leaks, whoever holds it can sign files for those hosts. In both cases, build a new store release with a new key.

Each time a device installs a file, native code checks that:

1. its size matches its header and is at most 320 MiB, and its magic and version are FPTC v1;
2. its fingerprint is this host's, so a file for another app, version, flavor, channel, ABI or build cannot install;
3. the payload matches its SHA-256 and, on a signed host, the signature verifies with the host's key;
4. its sequence is above the highest the device has accepted, of a patch or a withdrawal, so an older file cannot be replayed;
5. the patch is not on the device's blacklist.

If any check fails, nothing is installed; the result of each case is listed in [What a device accepts](api-reference.md#what-a-device-accepts). Before loading the installed patch at each cold start, the device checks it again: on a bytecode host the whole file as above, on an SO host the unpacked files against what was verified at install.

## Life on the device

```text
the app gets    through the built-in downloader (checkUpdate / applyPatch)
the file        or custom delivery (applyPatchBytes / applyPatchFile)
     ↓
apply           native code verifies the whole file → writes it and commits atomically;
                a withdrawal removes the installed patch
     ↓
(the app keeps running its current code)
     ↓
next cold       checks the installed patch again → loads it →
start           marks the start successful after the first frame
     ↓
failed start    past the threshold, returns to the app's built-in version
                and blacklists the patch
```

- A new patch or a withdrawal takes effect at the next cold start, because the running process keeps the code it loaded.
- Installation is atomic: power loss or a killed process leaves either the previous state or the new one.
- When the user upgrades the app, patches for the old version stop applying, because the fingerprint changed; the new version needs its own patches.
- How failed starts are detected and rolled back: [Crash Protection](crash-protection.md).

## What can be patched

| Change | Patchable | Why |
|---|:---:|---|
| Your Dart code | ✅ | |
| Pure-Dart dependencies | ✅ | Carried by the whole tier in bytecode patches |
| Added or changed assets (images, fonts, JSON…) | ✅ | The engine reads them from the patch; unchanged assets still come from the app |
| Removed assets | ❌ | A patch can override assets but not remove them |
| Asset changes on a host whose engine cannot install patch assets | ❌ | Hosts built with an older engine lack this; rebuild the host |
| Native code, native plugins, build scripts | ❌ | A patch carries only Dart code and assets |
| Dependencies with native capabilities | ❌ | They are tied to native code and change only with a new release |
| Packages that depend on those (bytecode) | ❌ | They stay in the host with the package they depend on |
| FFI calls in a package the patch carries (bytecode) | ❌ | The interpreter cannot make FFI calls; keep FFI calls in a package the host keeps, such as a plugin |
| `IconData` built at run time (bytecode) | ❌ | A patch's icon font keeps only the constant icons it uses |
| Flutter SDK version | ❌ | A patch is built with the same Flutter version as its host |

`patch` checks these limits and fails with an error code when a change breaks one. In the following cases it builds the patch but warns, because part of the change does not take effect:

| Warning | Case |
|---|---|
| `PATCH_NATIVE_ASSET_READER` | Native code that reads assets through the platform still sees the app's original copy of a changed asset |
| `PATCH_BACKGROUND_ENTRY` | An entry point that runs in another Flutter engine, such as one started by a background task or a push callback, and that the patch does not carry, runs the app's original code |
| `PATCH_RESOURCE_SIZE` | The patch's assets exceed 16 MB; they stay in memory for the life of the process |

Every error and warning code is in [Troubleshooting](troubleshooting.md).
