# flutter_patcher example

Build a host app, change it, and watch the patch load on the next cold
start. No server, no keys and no cloud account are needed.

You need Flutter 3.47.0–3.47.9 (`dart run flutter_patcher doctor` checks
yours) and an Android 9 or later phone connected over USB with debugging on.

## Android over USB

```bash
cd example
dart run flutter_patcher build android --out build/host
adb install build/host/app-release.apk
```

`build` warns `UNSIGNED`, `URL_LOCAL` and `BASELINE_STORE_LOCAL`; all three
are expected here. The app opens on **Running the installed version**. Start
`serve` in a second terminal and leave it running:

```bash
dart run flutter_patcher serve
```

Now change something: edit `message` in `lib/main.dart`, or copy
`assets/patch_demo_patched.png` over `assets/patch_demo.png`. Then make the
patch:

```bash
dart run flutter_patcher patch android
```

`serve` offers it to the phone at once. Tap **Check for update**, then close
and reopen the app: it shows your change and the patch it runs. Repeat for
every change.

To go back, `dart run flutter_patcher patch android --withdraw` makes a
withdrawal: tap **Check for update** and restart, and the app runs the
installed version again. **Roll back** does the same for this phone only.

## Your own delivery

A patch is one file: `patch` prints its path as `file`. `serve` is one way
to hand it to a phone; any other works the same. Download it from your own
server, receive it in a message, read it from storage, and pass it on:

```dart
final result = await FlutterPatcher.applyPatchBytes(bytes);
// or FlutterPatcher.applyPatchFile(path)
```

`(await FlutterPatcher.patchTarget).fileName` names the file this host takes. The
phone checks every file itself, however it arrived.

## iOS

On an Apple Silicon Mac with signing (Team and Bundle ID) set up in Xcode,
build in a Terminal of the Mac's desktop session, where code signing can reach
the keychain. `development` makes an app your registered iPhone installs; the
default, `app-store`, needs a distribution certificate:

```bash
dart run flutter_patcher build ios --export-method development --out build/host
```

Install `build/host/app-release.ipa` on the iPhone (Xcode's Devices window, or
`xcrun devicectl device install app`), and make patches with `patch ios`. An
iPhone cannot reach the Mac's 127.0.0.1, so expose `serve` over HTTPS, for
example with `cloudflared tunnel --url http://127.0.0.1:8686`, and enter that
URL in the app's **Update address** field.
## Going to production

Put the files `patch` writes on any HTTPS host with a short cache time, as
`<url>/<file name>`, and set `url` in `flutter_patcher.yaml` to that address
before the build you ship; `checkUpdate()` then looks there. `publish` can do
the upload for you, numbering files in the order you publish them. To sign
patches, run `dart run flutter_patcher keys init` before that build. Set
`baseline_store` to durable storage: every patch of a build needs its
baseline. See the [Production Deployment Guide](../doc/production-playbook.md).
