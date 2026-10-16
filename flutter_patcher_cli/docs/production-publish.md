# Production publication protocol (WP-2.2)

Production publication currently runs on Linux x64/WSL2 with OpenSSL and an AWS
CLI that supports `s3api put-object --if-match` and `--if-none-match`. Existing
`publish --out ... --action stage|serve|withdraw` remains a local mock.

```sh
flutter_patcher publish --production --request publish.json --receipt preview.json
flutter_patcher publish --production --request publish.json --commit --receipt committed.json
```

Without `--commit`, baseline reads, payload verification and signing run, but no
publication object is uploaded. Receipt output paths must be new. Use a stable
32-character random lowercase hexadecimal operation ID (for example a UUID
without hyphens). Retrying requires the same request, keys and payload bytes.

Example request (replace all identities and paths with the actual baseline):

```json
{
  "kind": "publish",
  "application_id": "com.example.app",
  "operation": "0123456789abcdef0123456789abcdef",
  "store": "s3://YOUR_BUCKET/YOUR_APPLICATION_PREFIX",
  "baseline_store": "s3://YOUR_BUCKET/YOUR_BASELINE_PREFIX",
  "public_base_url": "https://updates.example.com/app",
  "private_key": "/private/publication/private-key.base64",
  "public_key": "/private/publication/public-key.base64",
  "patch": "/build/patch.fptc",
  "expected_revision": 0,
  "created_at": 1789344000,
  "pin": true,
  "fields": {
    "schema": "1",
    "key_id": "release",
    "application_id": "com.example.app",
    "channel": "stable",
    "flavor": "default",
    "version_code": "1",
    "abi": "arm64-v8a",
    "fingerprint": "REPLACE_WITH_64_LOWERCASE_HEX",
    "strategy": "bytecode",
    "revision": "1",
    "minPluginVersion": "2.0.0",
    "action": "publish",
    "patch_seq": "1"
  }
}
```

`created_at` is a fixed administrative retention timestamp in epoch seconds,
not a device freshness guarantee. The tool derives the file SHA256, size and URL.
`expected_revision` is the last current revision in this target scope, or zero
for its first release. Revisions must increase. Do not silently increment a
revision after conflict; inspect the current publication and prepare a new request.

`store` must be a dedicated application namespace. Use `file:///...` for local
integration. Do not overlap a file publication namespace with its baseline store.
Old baseline archives remain unchanged. Their sidecar and full archive must exist
remotely; each operation verifies them through a fresh cache, including the
application/version/public key in the integrity-protected build receipt.
The existing baseline fingerprint and FPTC signature are verified before upload.

S3 authentication uses the normal AWS environment/profile chain. For R2 or an
S3-compatible service set `FLUTTER_PATCHER_S3_ENDPOINT` to its HTTPS service
endpoint, and configure the region required by the service (R2 uses `auto`).
Never put credentials into URLs or request JSON. A service without conditional
PUT support is rejected; there is no unconditional write fallback. Bucket-level
configuration, bucket creation and bucket enumeration are not part of this command.

The publication key is separate from the host's FPTC key. Configuring a public key
here proves only that signing uses its matching private key; it does not install
that key into existing hosts. WP-2.3 provides host trust configuration and device
consumption. The original SO workflow remains available; this new production
pipeline currently accepts bytecode only.

## Objects and transaction contract

- `objects/<operation>/<sha256>.fptc`: immutable, generation-specific payload.
- `catalog.json`: application identity, operation journal, release records and
  `heads` mapping a target scope hash to the current release operation.
- Each release record contains the exact WP-2.1 signed `wire` envelope. The
  catalog itself is storage metadata, not an authenticated device manifest.

The update service/adapter must select the correct `heads` entry and return its
exact signed envelope to the device. Do not pass the entire catalog to the old
`checkUpdate` parser. Do not trust catalog metadata as a substitute for device
verification. `public_base_url` must actually serve the namespace's object paths;
S3 readback does not prove the CDN mapping or unauthenticated device access. The
receipt explicitly records `public_download_verified: false`.

The catalog is the single commit point: current selection, history, references
and the receipt change together by conditional PUT. A pending non-expiring gate
serializes publishers and cleaners across machines. No later operation can steal
it. If interrupted, restore the original inputs and repeat the same operation.
Never manually remove the gate while a worker could still be running. Stale
plans rejected before side effects are journaled and release their gate.

This trades availability after a lost operation for predictable recovery. Keep
request files and keys backed up. There is no automatic timeout, forced unlock,
or general administrative repair command in this version. Operation IDs and
payload paths cannot be reused even after retention deletion. Late writes to an
old generation cannot replace a current payload; late deletes cannot delete a
new generation with identical bytes.

ETags are opaque concurrency tokens, not hashes. Unknown write outcomes are
resolved by readback or reported as unknown, allowing the identical request to be
retried. The operation journal records its prior catalog token and committed
generation. Data hashes and the verified baseline's engine/build identity are
included in receipts. Patch source and publisher source are explicitly marked
unrecorded rather than inferred from an unrelated working checkout.

The catalog is bounded to 8 MiB and reserves capacity before starting work. A
full catalog rejects further operations; catalog archival requires a later
version. Unknown/out-of-band writers are unsupported in a managed namespace.

## Signed withdrawal

Create a new operation and higher revision. Remove `patch`, `patch_seq`, and any
payload fields; set `action` to `withdraw` and `withdraw_through_seq` to the maximum
patch sequence being withdrawn. Keep the same target scope and baseline store.
The command commits a signed withdrawal record; it does not report device rollback.
Publication after withdrawal must satisfy the sequence high-water mark and cannot
resurrect a withdrawn sequence. An identical operation is an idempotent retry.

## Retention

Prepare a request with `kind: "cleanup"`, application identity, store, a new
operation ID, and an explicit epoch-seconds `cutoff`. Run without `--commit` and
save its output using `--receipt cleanup-plan.json`. Then add
`"approved_plan": "/absolute/path/cleanup-plan.json"` to the request and execute
with `--commit` only when deletion of the listed objects is authorized.

Current heads, pinned releases and releases newer than the cutoff are protected.
Pin rollback/retry targets when publishing. Cleanup rechecks references under the
same operation gate and verifies each object hash/size before deletion. Partial
deletion remains resumable with the identical approved plan. Historical metadata
and operation IDs remain, so deleted generations cannot be republished accidentally.

External baseline archives are always protected: old baseline writers do not
participate in this gate. This tool never deletes those archives. Arbitrary
unregistered objects and orphan objects are not silently garbage-collected.

## Validation

`publication_test.dart` tests lost replies, conflicts, interrupted cleanup,
replays, signatures and the native policy vectors. `publication_baseline_test.dart`
uses a synthetic signed fixture with a real baseline archive and CLI entrypoint.
`publication_s3_test.dart` requires an isolated S3 endpoint and test credentials;
the legacy S3 baseline tests run against that endpoint as well.
`publication_cloud_test.dart` is opt-in and restricted to a separately authorized
`flutterpatcher/cloud-test/<random>` namespace. It is not an automatic CI job.

No APK rebuilding, device installation, key rotation, or remote Git/release
publication is performed by these storage tests.
