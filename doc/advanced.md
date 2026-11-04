<!-- ========================================== -->
<!-- doc/advanced.md (English)                  -->
<!-- ========================================== -->

# Advanced Operations

**English** | [简体中文](advanced-zh.md)

This guide covers operations needed only occasionally. For everyday configuration and the release workflow, see the [Production Playbook](production-playbook.md).

## Rotating the Publisher Key

If the `publisher` private key is lost or leaked, use the `root` private key to sign a new trust document that replaces the publisher public key devices trust, without shipping a new app release. The `patch` and `root` keys cannot be replaced over the air; replacing them requires a new app release.

Devices apply a trust document through `updatePublicationTrust`, so your app needs to include this call (for example, triggered by remote config):

```dart
final doc = await FlutterPatcher.fetchSignedManifest(
  'https://cdn.example.com/my-app-trust/trust.json',
);
await FlutterPatcher.updatePublicationTrust(doc);
```

### Steps

1. Generate a new publisher key: `dart run flutter_patcher keys init --out new-publisher.json --role publisher`. The output shows its public key.

2. Prepare `fields.json` with the target release's 7 identifying fields, plus `schema`, `revision` and the new `keys`:

   ```json
   {
     "application_id": "com.example.app",
     "channel": "production",
     "flavor": "default",
     "version_code": "1",
     "abi": "arm64-v8a",
     "fingerprint": "<baseline_fingerprint>",
     "strategy": "bytecode",
     "schema": "1",
     "revision": "1",
     "keys": "release:<new_publisher_public_key>"
   }
   ```

   - `keys` uses the `release:<public key>` form: `publish` in a project always signs with the key ID `release` (a `--production` request file names its own `key_id`).
   - `revision` must increase with every rotation.

3. Sign with the `root` private key and publish the trust document:

   ```bash
   dart run flutter_patcher trust sign --fields fields.json --out trust-1.json

   dart run flutter_patcher trust publish --wire trust-1.json \
     --store s3://my-bucket/my-app-trust
   ```

   `trust sign` takes the root key the way `publish` takes its keys (see [Where private keys come from](cli.md#where-private-keys-come-from)), for example `--key-file root-backup.json` with the backup you keep offline.

   Each live release has its own trust document; give each release its own `--store` location. `trust publish` fails with `TRUST_SCOPE_CONFLICT` when the location already holds another release's document.

4. Adopt the new key with `dart run flutter_patcher keys import new-publisher.json --rotate` and commit `flutter_patcher.yaml`, then create and publish your latest patch again. Machines and CI jobs that publish need the new key too (`keys export`).

### How Rotation Takes Effect

Once a device applies the new trust document, manifests signed with the old `publisher` key are no longer accepted, and a patch installed through one is removed at once. Publish a patch with the new key right after rotating so devices stay on your latest patch.

## Cleaning Up Old Patches

Old patches in the publication store are not deleted automatically. To free space, prepare a cleanup request file, `cleanup.json`:

```json
{
  "kind": "cleanup",
  "application_id": "com.example.app",
  "store": "s3://my-bucket/my-app",
  "operation": "<32-character random lowercase hex string>",
  "cutoff": 1790000000
}
```

1. Create a cleanup plan; nothing is deleted yet:

   ```bash
   dart run flutter_patcher publish --production --request cleanup.json --receipt cleanup-plan.json
   ```

2. Review `cleanup-plan.json`, add `"approved_plan": "<absolute path to cleanup-plan.json>"` to `cleanup.json`, then run:

   ```bash
   dart run flutter_patcher publish --production --request cleanup.json --yes
   ```

Cleanup never deletes each release's current patch, patches created at or after `cutoff`, records published with `"pin": true`, or any baseline in the baseline store.
