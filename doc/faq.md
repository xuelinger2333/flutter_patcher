<!-- ========================================== -->
<!-- doc/faq.md (English)                       -->
<!-- ========================================== -->

# Frequently Asked Questions (FAQ)

**English** | [简体中文](faq-zh.md)

### Can a patch add or change images and fonts?

Yes, for assets declared in `pubspec.yaml`. A patch cannot delete an asset that the installed app has (`PATCH_ASSET_DELETE_UNSUPPORTED`); that needs a store release. When patched assets exceed 16 MB in total, `patch` warns with `PATCH_RESOURCE_SIZE`: they stay in memory for the life of the process.

### Can a patch add a new package?

Only a pure-Dart package. Packages with native code, platform plugins and FFI packages need a store release; `patch` fails with `PATCH_NATIVE_CHANGE`. Packages that native code depends on stay at the version the app was built with (`PATCH_PINNED_PACKAGE_CHANGED`). The full list is in [How It Works: What can be patched](architecture.md#what-can-be-patched).

### How big is a patch?

A bytecode patch carries only the changed code and assets: changing one line of text in the example app made a patch of about 19 KB. An SO patch carries the whole recompiled `libapp.so`, several megabytes. A patch file can be at most 320 MiB; the built-in downloader (`applyPatch`) must finish within 2 minutes.

### Can a patch take effect without restarting the app?

No. A patch runs from the next cold start; the running process keeps its code. The plugin does not restart the app for you.

### Can an app built with plain `flutter build` receive patches?

No. Only apps built with `flutter_patcher build` accept patches. If a plain build is already in the store, release one built with `flutter_patcher build` first.

### Does the bytecode strategy slow the app down?

Without a patch, the app runs exactly as a normal release build. With a patch, only the changed functions run in the interpreter, slower than machine code; everything else still runs as machine code. A change to compute-heavy code runs noticeably slower; on Android, the `so` strategy runs patches at full speed, with larger patches. See [How It Works: Two patch strategies](architecture.md#two-patch-strategies).

### What happens when I upgrade Flutter?

You build and release a new store version. Patches never cross Flutter versions: patches for an older release are made with the Flutter version that built it, for example with `--flutter-sdk`.

### What happens to a patch when a user updates the app from the store?

It stops applying, and the boot diagnostic is `droppedVersionCodeMismatch`. Each patch belongs to one build number; if the new release needs a fix, publish a patch for it.

### Can I patch several live releases?

Yes. Each release has its own baseline and its own patch file name, `<version_code>-<flavor>-<channel>-<abi>.fptc`. Go back to that release's source, fix it, and run `patch --version-code <its build number>`. See the [Production Deployment Guide](production-playbook.md).

### Do I need keys?

No. Without a key, `build` makes an unsigned host and prints `WARNING: UNSIGNED`: it accepts any file of its own build, so whoever can hand the app a file can run code in it. To sign, run `dart run flutter_patcher keys init` and build again: hosts built from then on accept only files signed by that patch key. Hosts already released keep the mode they were built with. See [How It Works: Security model](architecture.md#security-model).

### Can someone who controls my storage or CDN push a patch?

On a signed host, no. The device installs only files signed with your patch key, for exactly its app, version, flavor, channel, ABI and build, numbered above every file it has accepted. Without the private key, changed content only fails verification. On an unsigned host, yes: anyone who can change the file your app receives can run code in it.

### Can my app download patches its own way?

Yes. The plugin does not fetch patches. Get the file however you like (your own API, a CDN, push, a file bundled with the app, a file picker) and pass its bytes to `FlutterPatcher.applyPatchBytes` or its path to `applyPatchFile`. `FlutterPatcher.patchTarget` tells your server which file the device needs (`fileName`, version code, flavor, channel, ABI) and the highest sequence it has accepted (`acceptedSeq`). `checkUpdate` and `applyPatch` are only a built-in downloader for files placed at a URL. See [Advanced Operations: Serving patch files from your own API](advanced.md#serving-patch-files-from-your-own-api).

### How do I roll back or withdraw a patch?

- **Back to the installed version**: `dart run flutter_patcher patch android --withdraw` (or `ios`) writes a withdrawal file under the same name; deliver it like a patch, or use `publish --withdraw`, which writes it to the store. Devices that apply it drop their patch at the next cold start.
- **Back to an earlier patch**: `dart run flutter_patcher publish --patch <that patch's output directory>` seals it again with a new sequence.
- **One device**: `FlutterPatcher.rollback()`.

Uploading an old `.fptc` again has no effect: its sequence is not above the one devices accepted. Deleting the file only stops new installs; devices that have it keep it. Which users get which file (gray release, per user) is your server's choice. See the [Production Deployment Guide](production-playbook.md).

### What if a patch crashes the app at startup?

The device turns the patch off, runs its installed version from the next cold start, and blacklists the patch. Withdraw it or publish a fix promptly, because devices that have not tried it can still install it. See [Crash Protection](crash-protection.md#what-to-do-when-it-trips).

### Do I need my own backend?

No. Patch files are static files: `patch` writes `<fileName>.fptc` into its output directory (and `publish`, if you use it, at the root of its store), and any HTTPS static hosting can serve it, such as AWS S3, Cloudflare R2, Alibaba Cloud OSS or Google Cloud Storage behind a CDN. Give `.fptc` files a short cache time: each new patch replaces the file under the same name. See the [Production Deployment Guide](production-playbook.md).

### What happens to my 1.0 hosts?

They keep working as they are: they install only 1.0 signed manifests, so make, publish and withdraw their patches with flutter_patcher 1.0.0+1. On 1.1, `patch` for a 1.0 baseline fails with `PATCH_BASELINE_INCOMPATIBLE`. Your 1.0 project and keys work with 1.1 unchanged, and the next `build` makes a 1.1 host. The 1.0 files in the store (`manifests/`, `objects/`, `catalog.json`) are neither read nor written by 1.1 and keep serving 1.0 hosts. See [CHANGELOG: Upgrading from 1.0](../CHANGELOG.md#upgrading-from-10).

### Can I make iOS patches on Linux or Windows?

Yes. Only `build ios` needs an Apple Silicon Mac; `patch ios` runs on any supported computer that can read the baseline `build ios` saved.

### Are x86 emulators or 32-bit Android devices supported?

No. On Android, hosts and patches are `arm64-v8a` only.

### Do app stores allow this?

Policies differ between stores and between regulated industries such as finance, health and apps for children; some restrict downloading executable code. Check the rules of the stores and industries you ship in.

### Why does `patch` on Windows say every file changed?

Git converted line endings to `CRLF`, so the files differ byte for byte from a baseline built with `LF`. The fix is in [Error Codes and Troubleshooting](troubleshooting.md).
