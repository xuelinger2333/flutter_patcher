# flutter_patcher example

> Build the example app as a host, change its text or image, and run the change on a phone as a patch.

You have this repository checked out and want to see a patch run before integrating flutter_patcher into your own app. Android runs over USB with no server and no key. iOS needs a Mac and a tunnel. The full first-run flow for your own project is in [Getting Started](../doc/getting-started.md).

You need:

- Flutter 3.47.0 to 3.47.9 (`dart run flutter_patcher doctor` checks it);
- an `arm64-v8a` phone on Android 9 or later, connected over USB with USB debugging on.

## Android over USB

1. Build the host and install it:

   ```bash
   cd example
   dart run flutter_patcher build android --out build/host
   adb install build/host/app-release.apk
   ```

   `build` prints the warnings `UNSIGNED` and `BASELINE_STORE_LOCAL`; both are expected here. The app opens showing **Running the installed version**. `--out` must name a directory that does not exist, so delete `build/host` before building again.

2. In a second terminal, in `example`, start `serve` and leave it running:

   ```bash
   dart run flutter_patcher serve   # Offers the newest patch at 127.0.0.1:8686 to the phone over adb reverse
   ```

3. Change something: edit `message` in `lib/main.dart`, or copy `assets/patch_demo_patched.png` over `assets/patch_demo.png`. Then make the patch:

   ```bash
   dart run flutter_patcher patch android
   ```

4. In the app, tap **Check for update**, then close the app and open it again. The screen shows your change and **Running patch <seq>**.

Repeat steps 3 and 4 for every change; `serve` picks up each new patch within about 2 seconds.

To return to the installed version, make a withdrawal file and deliver it the same way:

```bash
dart run flutter_patcher patch android --withdraw
```

Tap **Check for update** and restart the app: it shows **Running the installed version** again. **Roll back** removes the patch on this phone only, without a withdrawal file.

## Custom delivery

A patch is one file; `patch` prints its path as `file`. `serve` is one way to hand it to a phone. The app can also obtain the file through its own channel, such as your server, a message or local storage, and install it:

```dart
// Verifies and installs a patch file the app obtained itself.
final result = await FlutterPatcher.applyPatchBytes(bytes);
```

`(await FlutterPatcher.patchTarget).fileName` is the name of the file this host takes. See [Custom Delivery from Your Own Server](../doc/advanced.md#custom-delivery-from-your-own-server).

## iOS

You need an Apple Silicon Mac with signing (Team and Bundle ID) set up in Xcode for the example app, and an iPhone registered with that team.

1. Build in a Terminal window of the Mac's desktop session, because code signing reaches the keychain only there:

   ```bash
   dart run flutter_patcher build ios --export-method development --out build/host
   ```

   `development` makes an app your registered iPhone can install; the default, `app-store`, needs a distribution certificate.

2. Install `build/host/app-release.ipa` on the iPhone, for example in Xcode's Devices and Simulators window.
3. An iPhone cannot reach the Mac's `127.0.0.1`. Start `serve`, expose it over HTTPS with a tunnel, and enter the tunnel's address in the app's **Update address** field:

   ```bash
   cloudflared tunnel --url http://127.0.0.1:8686   # Prints an https:// address that forwards to serve
   ```

4. Make patches with `dart run flutter_patcher patch ios`, then tap **Check for update** and restart the app as on Android.

Other iOS differences are listed in [Differences on iOS](../doc/getting-started.md#differences-on-ios).

## Going to production

Before building the release you ship:

- pass the HTTPS address that serves the patch files as `checkUpdate(url: …)`, or use custom delivery;
- set `baseline_store` to durable storage, because every patch of a build needs its baseline;
- run `dart run flutter_patcher init` and set `trust.enabled: true` in `flutter_patcher.yaml`, so the app accepts only patches you signed.

The steps are in the [Production Deployment Guide](../doc/production-playbook.md).
