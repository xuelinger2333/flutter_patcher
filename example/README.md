# flutter_patcher example

This example demonstrates the local hot-patch flow without a server.

## Run

```bash
flutter build apk --release
flutter install
```

Open the app, tap **Apply patch**, then cold-start the app again. The bundled
`assets/libapp_preload.so` is installed through `FlutterPatcher.applyPatchBytes`
and takes effect on the next cold start.

Tap **Rollback** and cold-start again to return to the APK-bundled `libapp.so`.

## Mock server

The repository also includes a small HTTP mock server for testing
`checkUpdate -> applyPatch`:

```bash
dart run flutter_patcher:pack \
  --apk path/to/app-release.apk \
  --version dev-1 \
  --target-version-code 1

dart run example/tools/mock_server.dart dist 8080
```

The mock server reads `dist/libapp.so`, matching the pack CLI output.
