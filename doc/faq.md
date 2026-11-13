# FAQ

**English** | [简体中文](faq-zh.md)

> Short answers on what a patch can change, signing, delivery and rollback, and supported platforms, each with a link to the page that explains it.

You are deciding whether flutter_patcher fits your app, or you have one specific question. Each answer starts with yes or no and gives the reason; the linked page has the details. For an error code, see [Troubleshooting](troubleshooting.md).

## Patches

### Can a patch add or change images and fonts?

Yes, for assets declared in `pubspec.yaml`. A patch cannot delete an asset the installed app contains, because a patch only overrides assets: `patch` fails with `PATCH_ASSET_DELETE_UNSUPPORTED`. See [What can be patched](architecture.md#what-can-be-patched).

### Can a patch add a new package?

Yes, if the package is pure Dart. A package with native code, a platform plugin or an FFI package fails with `PATCH_NATIVE_CHANGE`, because a patch carries only Dart code and assets. See [What can be patched](architecture.md#what-can-be-patched).

### Can a patch take effect without restarting the app?

No. A patch runs from the next cold start, because the running process keeps the code it loaded. See [Life on the device](architecture.md#life-on-the-device).

### Does a patch contain the whole app?

A bytecode patch starts with changed libraries, their required callers and parts, and changed assets. It reuses unchanged libraries where the released host's interface permits it. Missing APIs expand the selection; if needed, the compiler falls back to carrying the application package and all free Dart dependencies. Barrel imports and cycles can also bring in many unchanged libraries. Flutter and native plugins stay in the app. An SO patch carries the whole recompiled `libapp.so`, several megabytes. A patch file is at most 320 MiB, and the built-in downloader must finish within 2 minutes. See [Two patch strategies](architecture.md#two-patch-strategies).

### Does the bytecode strategy slow the app down?

Yes, while a patch runs: an interpreter runs the application libraries carried by the patch, which is slower than machine code, so compute-heavy code in your app runs noticeably slower. Flutter and plugins still run as machine code, and without a patch the app runs as a normal release build. On Android, `--strategy so` runs patches at full speed with larger patch files. See [Two patch strategies](architecture.md#two-patch-strategies).

### Can an app built with plain `flutter build` receive patches?

No. Only apps built with `dart run flutter_patcher build` accept patches, because only they contain the engine and entry point that load one. Release a version built that way first. See [The host: an app that accepts patches](architecture.md#the-host-an-app-that-accepts-patches).

### Can a patch be made with another Flutter version than its release?

No. A patch is built with the Flutter version that built its release, so after upgrading Flutter, ship a new store release; for an older release, select its Flutter with `--flutter-sdk`. See [What can be patched](architecture.md#what-can-be-patched).

### Does a patch survive a store update of the app?

No. A patch belongs to one build number, so after the update it stops applying and the boot diagnostic is `droppedVersionCodeMismatch`. Make a patch for the new build if it needs the fix. See [Other ways a patch stops applying](crash-protection.md#other-ways-a-patch-stops-applying).

### Can I patch several live releases?

Yes. Each release has its own baseline and its own patch file name, such as `7-arm64-v8a.fptc`: check out that release's source, fix it, and run `patch android --version-code <its build number>`. See [5. Make and Deliver a Patch](production-playbook.md#5-make-and-deliver-a-patch).

## Security and keys

### Do I need keys?

No. Without a key, `build` prints `WARNING: UNSIGNED` and the app installs any intact patch file of its build, so whoever can hand the app a file can run code in it. With `trust.enabled: true` in `flutter_patcher.yaml` before the build you ship, the app installs only files you signed. See [3. Turn On Signing](production-playbook.md#3-turn-on-signing).

### Can someone who controls my storage or CDN push a patch?

No, not to a signed app: it installs only files signed with your patch key, made for exactly its build and numbered above every file it accepted. An unsigned app installs any intact file of its build. See [Security model](architecture.md#security-model).

## Delivery and operations

### Can my app download patches its own way?

Yes. The app obtains the file through any channel, such as your own API, a push message or a bundled file, and passes it to `FlutterPatcher.applyPatchBytes` or `applyPatchFile`. See [Custom delivery](advanced.md#custom-delivery-from-your-own-server).

### Do I need my own backend?

No. A patch is one static file, so any HTTPS static hosting or CDN can serve it. See [1. Decide Where the App Gets Patch Files](production-playbook.md#1-decide-where-the-app-gets-patch-files).

### Can I roll back a patch?

Yes. Deliver a withdrawal file (`patch android --withdraw`) to return devices to the installed version, or publish an earlier patch's output again to return to that patch. Uploading an old `.fptc` file again has no effect, because devices accept only a higher sequence. See [Delivering a rollback](production-playbook.md#delivering-a-rollback).

### Does the app recover when a patch crashes at startup?

Yes. The device turns the patch off, blacklists it, and runs the installed version from the next cold start. Devices that have not tried the patch still install it, so deliver a withdrawal or a fix. See [What to do when it trips](crash-protection.md#what-to-do-when-it-trips).

### Can apps shipped with flutter_patcher 1.0 still be patched?

Yes, with flutter_patcher 1.0.0+1. On 1.1, `patch` for a 1.0 baseline fails with `PATCH_BASELINE_INCOMPATIBLE`; the project and keys work with 1.1 unchanged, and the next `build` makes a 1.1 app. See [Upgrading from 1.0](upgrading.md).

## Platforms

### Can I make iOS patches on Linux or Windows?

Yes. Only `build ios` needs an Apple Silicon Mac; `patch ios` runs on any supported computer that can read the baseline `build ios` saved. See [Differences on iOS](getting-started.md#differences-on-ios).

### Are x86 emulators or 32-bit Android devices supported?

No. On Android, apps and patches support `arm64-v8a` only.

### Does a Windows checkout change what `patch` compares?

Yes, when Git converts line endings to `CRLF`: the files then differ byte for byte from a baseline built with `LF`, and `patch` reports every file as changed. The fix is in [Troubleshooting](troubleshooting.md).

### Is this allowed in every app store?

No. Policies differ between stores and between regulated industries such as finance, health and apps for children, and some restrict downloading executable code. Check the rules of the stores and industries you ship in.
