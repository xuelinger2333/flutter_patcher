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

A bytecode patch carries only the changed code and assets: changing one line of text in the example app made a patch of about 19 KB. An SO patch carries the whole recompiled `libapp.so`, several megabytes. A published patch can be at most 320 MB, and devices must download it within 2 minutes.

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

Yes. Each release has its own baseline and its own sequence numbers. Go back to that release's source, fix it, and run `patch --version-code <its build number>`. See [Production Deployment Guide: Patching Older Live Releases](production-playbook.md#patching-older-live-releases).

### Can someone who controls my storage or CDN push a patch?

No. Devices install only patches whose manifest is signed with your publisher key and whose patch is signed with your patch key, for exactly their app, version, flavor, channel and ABI, with a sequence higher than any they have accepted. Without your private keys, changed content only fails verification. See [How It Works: Security model](architecture.md#security-model).

### What if a patch crashes the app at startup?

The device turns the patch off, runs its installed version from the next cold start, and blacklists the patch. Withdraw it or publish a fix promptly, because devices that have not tried it can still install it. See [Crash Protection](crash-protection.md#what-to-do-when-it-trips).

### Do I need my own backend?

No. Patches and manifests are static files. Any HTTPS static hosting works, such as AWS S3, Cloudflare R2, Alibaba Cloud OSS or Google Cloud Storage behind a CDN. See [Production Deployment Guide: Sync to Static Storage](production-playbook.md#5-sync-to-static-storage).

### Can I make iOS patches on Linux or Windows?

Yes. Only `build ios` needs an Apple Silicon Mac; `patch ios` runs on any supported computer that can read the baseline `build ios` saved.

### Are x86 emulators or 32-bit Android devices supported?

No. On Android, hosts and patches are `arm64-v8a` only.

### Do app stores allow this?

Policies differ between stores and between regulated industries such as finance, health and apps for children; some restrict downloading executable code. Check the rules of the stores and industries you ship in.

### Why does `patch` on Windows say every file changed?

Git converted line endings to `CRLF`, so the files differ byte for byte from a baseline built with `LF`. The fix is in [Troubleshooting](troubleshooting.md#changed-a-single-line-of-dart-but-every-file-shows-as-modified-or-fails-with-patch_native_change).
