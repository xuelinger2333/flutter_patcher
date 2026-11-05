<!-- ========================================== -->
<!-- doc/advanced.md (English)                  -->
<!-- ========================================== -->

# Advanced Operations

**English** | [简体中文](advanced-zh.md)

Operations you need only occasionally. Everyday setup and publishing are in the [Production Deployment Guide](production-playbook.md).

## Rotating the Publisher Key

**Goal**: replace a lost or leaked `publisher` key without a new store release. The `patch` and `root` keys cannot be replaced this way; replacing them takes a new store release.

**Before**:

- The app applies trust documents. Include this call, for example triggered by remote config:

  ```dart
  final doc = await FlutterPatcher.fetchSignedManifest(
    'https://cdn.example.com/my-app-trust/trust.json',
  );
  await FlutterPatcher.updatePublicationTrust(doc);
  ```

- You have the `root` private key, such as the offline backup from `keys export`.

**Do**:

1. Create a new publisher key. The output shows its public key:

   ```bash
   dart run flutter_patcher keys init --out new-publisher.json --role publisher
   ```

2. Write `fields.json` for the live release: its 7 identifying fields, plus `schema`, `revision` and the new `keys`. The `fingerprint` is `scope.fingerprint` in that release's `patch.json`, or `fingerprint` in a `publish` result:

   ```json
   {
     "application_id": "com.example.app",
     "channel": "production",
     "flavor": "default",
     "version_code": "1",
     "abi": "arm64-v8a",
     "fingerprint": "<baseline fingerprint>",
     "strategy": "bytecode",
     "schema": "1",
     "revision": "1",
     "keys": "release:<new publisher public key>"
   }
   ```

   - `keys` takes the form `release:<public key>`: `publish` in a project always signs with the key ID `release` (a `--production` request file names its own `key_id`).
   - `revision` must rise with every rotation.

3. Sign it with the `root` key and publish it. `trust sign` finds the root key the way `publish` finds its keys ([Where private keys come from](cli.md#where-private-keys-come-from)), for example `--key-file root-backup.json`:

   ```bash
   dart run flutter_patcher trust sign --fields fields.json --out trust-1.json
   dart run flutter_patcher trust publish --wire trust-1.json --store s3://my-bucket/my-app-trust
   ```

   Each live release has its own trust document; give each release its own `--store` location. A location that holds another release's document fails with `TRUST_SCOPE_CONFLICT`.

4. Adopt the new key and commit `flutter_patcher.yaml`. Machines and CI jobs that publish need the new key too (`keys export`):

   ```bash
   dart run flutter_patcher keys import new-publisher.json --rotate
   ```

5. Make and publish your latest patch again: `patch`, then `publish`.

**Check**:

- `trust sign` and `trust publish` succeed; the trust document is at the address the app fetches.
- `keys status` shows the new publisher public key.
- `publish` in step 5 prints `"status":"published"`.

Once a device applies the new trust document, manifests signed with the old `publisher` key are no longer accepted, and a patch installed through one is removed at once. Step 5 keeps devices on your latest patch.

## Cleaning Up Old Patches

**Goal**: free space in the publication store. Old patches are never deleted automatically.

**Do**:

1. Write a cleanup request, `cleanup.json`. `cutoff` is a Unix time in seconds; only patches created before it can be deleted:

   ```json
   {
     "kind": "cleanup",
     "application_id": "com.example.app",
     "store": "s3://my-bucket/my-app",
     "operation": "<32-character random lowercase hex string>",
     "cutoff": 1790000000
   }
   ```

2. Make a cleanup plan; nothing is deleted yet:

   ```bash
   dart run flutter_patcher publish --production --request cleanup.json --receipt cleanup-plan.json
   ```

3. Review `cleanup-plan.json`, add `"approved_plan": "<absolute path to cleanup-plan.json>"` to `cleanup.json`, and run:

   ```bash
   dart run flutter_patcher publish --production --request cleanup.json --yes
   ```

**Check**: step 2 writes `cleanup-plan.json` listing what would be deleted; step 3 succeeds and those objects are gone from the store.

Cleanup never deletes a release's current patch, patches created at or after `cutoff`, records published with `"pin": true`, or anything in the baseline store.

## Delivering Manifests Yourself

When devices must download through your own API rather than from the publication store, fetch the manifest and patch yourself and hand them to the plugin to verify and install. See [API Reference: Delivering manifests yourself](api-reference.md#delivering-manifests-yourself).
