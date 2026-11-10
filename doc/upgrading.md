# Upgrading from 1.0

**English** | [简体中文](upgrading-zh.md)

> Keep patching apps shipped with flutter_patcher 1.0.0, and move the project to 1.1.

You have apps built with flutter_patcher 1.0.0 in the store and are moving the project to 1.1. Patch files need flutter_patcher 1.1.0 or newer, so the shipped 1.0.0 apps keep being patched with flutter_patcher 1.0.0+1; the project, keys and store work with 1.1 unchanged.

| What | 1.1 behavior |
|---|---|
| Apps already shipped with 1.0.0 | Make, publish and withdraw their patches with flutter_patcher 1.0.0+1, in a checkout of that release with `flutter_patcher: 1.0.0+1` in `pubspec.yaml`. 1.1 rejects their baselines with `PATCH_BASELINE_INCOMPATIBLE` |
| The project | `flutter_patcher.yaml` keeps working: `trust.patch` is read (`root` and `publisher` are ignored), and `url`, `store`, `baseline_store`, `signing.command` and the commands keep their meaning. 1.0 key bundles in the key store are found by their patch key. The next `build` makes a 1.1 app, signed with that patch key. A 1.0 publish left unfinished (`.dart_tool/flutter_patcher/publish-pending.json`) is ignored by 1.1; finish it with 1.0.0+1 |
| The store | 1.0's `manifests/`, `objects/` and `catalog.json` stay in place and keep serving 1.0.0 apps. 1.1 writes `.fptc` files at the store root, next to them |
| Dart API | Removed: `SignedManifest`, `SignedUpdateResult`, `fetchSignedManifest`, `applySignedManifest`, `updatePublicationTrust`, because the signed-manifest protocol they belonged to is gone. Use `applyPatchBytes` or `applyPatchFile` for files the app fetches itself, and `checkUpdate` with `applyPatch` for files at a URL |
| CLI | Removed: `trust`, `publish --production` and `--request` (delete the file from the store instead), `keys import --rotate`, and the key roles `root` and `publisher` |
| Version shown | `currentVersion` returns the file's sequence (`seq`) |

## Related

- [Production Deployment Guide](production-playbook.md): build the release with 1.1 and deliver patches.
- [Changelog](../CHANGELOG.md): everything that changed in 1.1.0.
