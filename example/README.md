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
are expected here. The app opens on **Running the installed version**. Now
change something: edit `message` in `lib/main.dart`, or copy
`assets/patch_demo_patched.png` over `assets/patch_demo.png`. Then make the
patch and serve it:

```bash
dart run flutter_patcher patch android
dart run flutter_patcher serve
```

`patch` writes the patch file, `1-default-production-arm64-v8a.fptc`, into
its output directory. `serve` publishes it to the project's store
(`.flutter_patcher/updates/`), serves it at `127.0.0.1:8686` and maps that
port on the phone to this computer. Tap **Check for update**, then close and
reopen the app: it shows your change and the patch it runs. Leave `serve`
running; after the next change, run `patch android` again. **Roll back**
deletes the patch on the phone.

## iOS

`dart run flutter_patcher build ios` runs on an Apple Silicon Mac with signing
set up in Xcode. An iPhone cannot reach the Mac's 127.0.0.1, so expose
`serve` over HTTPS, for example with
`cloudflared tunnel --url http://127.0.0.1:8686`, and enter that URL in the
app's **Update address** field.

## Going to production

Upload the `.fptc` file `publish` writes (to `.flutter_patcher/updates/` by
default, or straight to `store: s3://…` in `flutter_patcher.yaml`) to an
HTTPS host with a short cache time, and set `url` in `flutter_patcher.yaml`
to that address before the build you ship; `checkUpdate()` then looks there.
Apps that fetch files themselves pass them to `FlutterPatcher.applyPatchBytes`
instead. To sign patches, run `dart run flutter_patcher keys init` before
that build. Set `baseline_store` to durable storage: every patch of a build
needs its baseline. See the
[Production Deployment Guide](../doc/production-playbook.md).
