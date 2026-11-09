# How It Works

**English** | [简体中文](architecture-zh.md)

This document explains why flutter_patcher works, why you can trust it, and where its limits are. It covers concepts only; for commands see the [CLI Reference](cli.md).

## Three roles

```text
  Your computer (CLI)              Wherever the app gets files         User's device (plugin)
 ─────────────────────           ─────────────────────────────       ──────────────────────
 build  → host + baseline                                            runs the host build produced
 patch  → one .fptc file  ──→    any HTTPS host, your own API,  ──→  applyPatchBytes / applyPatchFile
 publish → .fptc in a store       push, bundled, a file picker…       (or checkUpdate / applyPatch)
                                                                             │
                                                          verifies, installs; loads at the next cold start
```

- **Your computer**: `dart run flutter_patcher` builds the host app and its baseline, then turns each change into one patch file, such as `1-arm64-v8a.fptc`. Deliver that file any way you like; the optional `publish` writes it to a store (a directory or S3), and `serve` hands the newest one to development devices. The **baseline store**, which keeps the build record of every released version, is used only by the CLI.
- **Wherever the app gets files**: the plugin does not fetch patches. Your app gets the file in any way it likes and hands it to `applyPatchBytes` or `applyPatchFile`. `checkUpdate` and `applyPatch` are an optional built-in downloader for files placed at a URL.
- **Device**: native code checks every part of the file, installs it, and loads it on the next cold start.

## The host: an app that accepts patches

Patches install only on apps built with `flutter_patcher build`, called **hosts**. A host has three things a plain `flutter build` does not:

1. **The Flutter engine flutter_patcher provides**: the official engine with the abilities patch loading needs. The CLI downloads and verifies it for your Flutter version; your Flutter SDK is not modified.
2. **A generated entry point** that runs before your `main` and installs the patch at a cold start. Your source is not modified.
3. **The host policy**: the build's identity and, optionally, one public key, namely its application id, version code, flavor, channel, ABI, patch strategy and `fptc_key` (the patch public key, or `-` for an unsigned host). `build` writes it, with the compile fingerprint, into the APK (`assets/flutter_patcher/host-trust.json`) or Info.plist. Once the app is signed, the policy cannot change, and the device judges every patch file by it. A host keeps the mode it was built with: adding a key later changes only hosts built after it.

On Android a host applies patches on Android 9 (API 28) and later, in the app's main process; on older devices it runs the app as built.

## Two patch strategies

A Flutter release app compiles your Dart code to machine code. flutter_patcher can update it in two ways:

| | Bytecode (default) | SO |
|---|---|---|
| A patch contains | A bytecode module of the changed code | A whole recompiled `libapp.so` |
| How it runs | An interpreter in the engine runs the patch's code; unchanged code still runs as machine code | At startup, Flutter loads the patch's `libapp.so` instead |
| Platforms | Android, iOS | Android only |
| Patch size | Small: only the changes | Large: about the size of `libapp.so` |
| Speed of changed code | Interpreted, slower than machine code | Same as the original |

iOS does not allow loading downloaded machine code, so iOS hosts use bytecode. On Android you choose a strategy at `build`, and every patch of that release follows it.

Bytecode patches come in two tiers, which `patch` chooses for you: **lean** carries only your own packages and is tried first; when dependencies change, or lean cannot carry the change, **whole** also carries the patchable dependencies.

## Baselines: what a patch is compared with

A patch is the difference between your current code and the version on the user's phone, so the CLI must know that version exactly. Alongside the app, `build` saves its complete record as a **baseline**: compiled output, source hashes, dependencies, assets, the host policy, and the versions of the engine and tools it used.

`patch` finds the baseline by flavor and version number (Android versionCode, iOS CFBundleVersion), compares your current source with it, and packs only what changed.

Two rules apply to baselines:

- **Added, never replaced.** If the same version number builds to different content, `build` refuses instead of quietly replacing the record of a released version. To ship new content, raise the version number.
- **Tools stay fixed.** A baseline records the engine and tool versions it was built with, and every patch for that release uses the same ones. Even after flutter_patcher ships a newer engine, released apps can still be patched.

It follows that **a release whose baseline is lost can no longer be patched.**

## The patch file

A patch file (FPTC v1) is a 146-byte header followed by the payload, a ZIP of the patch:

| Offset | Bytes | Field |
|---:|---:|---|
| 0 | 4 | Magic `FPTC` |
| 4 | 2 | Format version, 1 |
| 6 | 32 | Fingerprint of the host it is for |
| 38 | 4 | Sequence (uint32, above 0) |
| 42 | 8 | Payload length |
| 50 | 32 | SHA-256 of the payload |
| 82 | 64 | Ed25519 signature over bytes 0–81 followed by the payload; 64 zero bytes when unsigned |
| 146 | | Payload |

- A file with an empty payload is a **withdrawal**: devices that apply it drop their patch.
- The **sequence** is the Unix time in seconds when the file was sealed, unless `publish --seq` gives another. A device accepts only files numbered above every file it has accepted.
- The **name** is `<version_code>-<abi>.fptc` for the default flavor and channel (`default`, `production`), for example `7-arm64-v8a.fptc`, and `<version_code>-<flavor>-<channel>-<abi>.fptc` otherwise, for example `7-paid-beta-arm64-v8a.fptc`. Flavors and channels contain only letters, digits and `_`, so no two hosts share a name. `patch` and `publish` name files this way, and `FlutterPatcher.patchTarget` gives the same `fileName` on the device, so an app or its server can pick the right file.
- A file is at most 320 MiB.

## Security model

There is one key, the **patch key**, and it is optional:

- **Signed host** (built while `trust.patch` in `flutter_patcher.yaml` names a public key): the device installs only files signed by that key. Storage, CDNs, the transport and however your app fetches the file **need not be trusted**: changed content only fails verification. This is also why `serve` can use plain HTTP while developing.
- **Unsigned host** (no key; `build` prints `WARNING: UNSIGNED`): the signature field is ignored, so whoever can hand the app a file can run code in it. The built-in downloader accepts only HTTPS, or plain HTTP to the device itself for `serve`; when the app fetches files itself, securing that channel is the app's job. An unsigned host also accepts signed files.

The private key never enters the project. `publish` signs with it, and so does `patch` when it finds it, from `--key-file` (publish only), the `FLUTTER_PATCHER_KEYS` environment variable, `signing.command` or the key store on your computer; see the [CLI Reference](cli.md). Building a host needs no private key.

If the patch key is lost, hosts built with it accept no new patch file; if it leaks, whoever holds it can sign files for them. Either way those hosts need a new store release built with a new key: the key in a released host cannot be replaced.

Each time a device installs a file, native code checks that:

1. its size matches its header and is at most 320 MiB, and its magic and version are FPTC v1;
2. its fingerprint is this host's, so a file for another app, version, flavor, channel, ABI or build cannot install;
3. the payload matches its SHA-256 and, on a signed host, the signature verifies with the host's key;
4. its sequence is above the highest the device has accepted, of a patch or a withdrawal, so an old file cannot be replayed;
5. the patch is not on the device's blacklist.

Applying the installed file again succeeds and changes nothing. If any check fails, nothing is installed. At every cold start the device checks the installed patch again before loading it: on a bytecode host the whole file as above, on an SO host the unpacked files against what was verified at install.

## Life on the device

```text
your app gets   from your API, a URL (checkUpdate / applyPatch), push, a bundled file…
the file
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

- A patch **never** replaces running code; a new patch or a withdrawal takes effect at the next cold start.
- Installation is atomic: power loss or a killed process never leaves half a patch.
- `rollback()` removes the installed patch on this device only. It does not blacklist the patch, and the highest accepted sequence stays, so only a newer file can install.
- When the user upgrades the app, patches for the old version stop applying.
- A device that ran a 1.0 host deletes the signed-manifest state 1.0 left (`noBackupFilesDir/flutter_patcher_auth/` on Android, `Application Support/flutter_patcher/auth/` on iOS) on its first start as a 1.1 host.
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
| Changed code that calls FFI (bytecode) | ❌ | The interpreter cannot make FFI calls |
| `IconData` built at run time (bytecode) | ❌ | A patch's icon font keeps only the constant icons it uses |
| Flutter SDK version | ❌ | A patch is built with the same Flutter version as its host |

These limits are checked by `patch`, which fails rather than shipping a broken patch. In a few cases the patch is built but part of it may not take effect, and `patch` warns:

- **Native code reads a changed asset**: native code that reads assets through the platform still sees the app's original copy.
- **Code runs in another Flutter engine**: entry points started by background tasks or push callbacks, for example, may run old code or use old assets.
- **Large patch assets** (over 16 MB): patch assets stay in memory for the life of the process.

The error code for each is in [Error Codes and Troubleshooting](troubleshooting.md).
