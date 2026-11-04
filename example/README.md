# flutter_patcher example

Build a host app, change it, and watch the signed patch load on the next cold
start. No server and no cloud account are needed.

You need Flutter 3.47.0–3.47.9 (`dart run flutter_patcher doctor` checks
yours) and an Android 9 or later phone connected over USB with debugging on.

## Android over USB

```bash
cd example
dart run flutter_patcher keys init
dart run flutter_patcher build android --out build/host
adb install build/host/app-release.apk
```

The app opens on **Running the installed version**. Now change something:
edit `message` in `lib/main.dart`, or copy `assets/patch_demo_patched.png`
over `assets/patch_demo.png`. Then make the patch and serve it:

```bash
dart run flutter_patcher patch android
dart run flutter_patcher serve
```

`serve` publishes the patch to the project's store and maps
`127.0.0.1:8686` on the phone to this computer. Tap **Check for update**,
then close and reopen the app: it shows your change and the patch it runs.
Leave `serve` running; after the next change, run `patch android` again.

## iOS

`dart run flutter_patcher build ios` runs on an Apple Silicon Mac with signing set up in
Xcode. An iPhone cannot reach the Mac's 127.0.0.1, so expose `serve` over
HTTPS, for example with `cloudflared tunnel --url http://127.0.0.1:8686`, and
enter that URL in the app.

## Going to production

In your own app, commit `flutter_patcher.yaml` (it holds only public keys) and
back up the private keys with `dart run flutter_patcher keys export --out
<file>`. Set `store` in `flutter_patcher.yaml` to an S3 prefix, serve it from any
HTTPS host, run `dart run flutter_patcher publish`, and pass that HTTPS URL to
`FlutterPatcher.checkUpdate`. Apps that deliver updates themselves pass the
manifest and patch to `FlutterPatcher.applySignedManifest`.