# How It Works

**English** | [简体中文](architecture-zh.md)

This document explains why flutter_patcher works, why you can trust it, and where its limits are. It covers concepts only; for commands see the [CLI Reference](cli.md).

## Three parties

```text
  Your computer (CLI)           Storage                      User's device (plugin)
 ─────────────────────        ───────────                  ──────────────────────
 build  → app + baseline  ──→  baseline store
 patch  → patch                                          runs the app build produced
 publish → signed manifest ──→ publication store ─(HTTPS)─→ checkUpdate / applyPatch
           + patch                                               │
                                                     loads the patch on the next cold start
```

- **Your computer**: `dart run flutter_patcher` builds the app, builds patches, signs and publishes them.
- **Storage**, of two kinds. The **baseline store** keeps the build record of every released version and is used only by the CLI. The **publication store** holds patches and manifests, which your HTTPS server or CDN serves to devices.
- **Device**: the plugin downloads a patch, checks every part of it in native code, installs it, and loads it on the next cold start.

## The host: an app that accepts patches

Patches install only on apps built with `flutter_patcher build`, called **hosts**. A host has three things a plain `flutter build` does not:

1. **The Flutter engine flutter_patcher provides**: the official engine with the abilities patch loading needs. The CLI downloads and verifies it for your Flutter version; your Flutter SDK is not modified.
2. **A generated entry point** that runs before your `main` and installs the patch at a cold start. Your source is not modified.
3. **The host policy**: identity and public keys built into the app, namely its application id, version, flavor, channel, ABI, patch strategy and three public keys. Once the app is signed, the policy cannot change, and the device judges every patch by it.

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

A patch is the difference between your current code and the version on the user's phone, so the CLI must know that version exactly. Alongside the app, `build` saves its complete record as a **baseline**: compiled output, source hashes, dependencies, assets, public keys, and the versions of the engine and tools it used.

`patch` finds the baseline by flavor and version number (Android versionCode, iOS CFBundleVersion), compares your current source with it, and packs only what changed.

Two rules apply to baselines:

- **Added, never replaced.** If the same version number builds to different content, `build` refuses instead of quietly replacing the record of a released version. To ship new content, raise the version number.
- **Tools stay fixed.** A baseline records the engine and tool versions it was built with, and every patch for that release uses the same ones. Even after flutter_patcher ships a newer engine, released apps can still be patched.

It follows that **a release whose baseline is lost can no longer be patched.**

## Security model

`keys init` creates three Ed25519 key pairs:

| Key | Signs | If it leaks |
|---|---|---|
| `patch` | The patch itself | Release a new host |
| `publisher` | The publication manifest: which patch a release should install | Replace it with the root key; no new release needed |
| `root` | Trust updates that replace the publisher public keys | Release a new host |

`build` puts the three **public** keys in the host policy. The **private** keys stay on your computer.

Each time a device installs a patch, native code checks that:

1. the manifest is signed by a publisher the host trusts;
2. the manifest's scope is exactly this host: application id, version, flavor, channel, ABI, strategy and compile fingerprint;
3. the patch's size and hash match the manifest, and the patch itself is signed with the patch key;
4. the patch's sequence number is above the highest the device has accepted, so an old patch cannot be replayed, and a withdrawn sequence never takes effect again.

If any check fails, nothing is installed. Storage, CDNs and the network therefore **need not be trusted**: tampered content only fails verification. This is also why `serve` can use plain HTTP while developing: it changes only the transport, and every check still runs.

## Life on the device

```text
checkUpdate   downloads this host's manifest and verifies it natively;
     ↓        hasUpdate only when there is something new
applyPatch    downloads the patch → verifies it → writes it and commits atomically
     ↓
(the app keeps running its current code)
     ↓
next cold     confirms the patch is still valid → loads it →
start         marks the start successful after the first frame
     ↓
failed start  past the threshold, returns to the app's built-in version
              and blacklists the patch
```

- A patch **never** replaces running code; it takes effect at a cold start.
- Installation is atomic: power loss or a killed process never leaves half a patch.
- When the user upgrades the app, patches for the old version stop applying.
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
