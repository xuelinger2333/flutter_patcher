# Authenticated bytecode updates

This opt-in workflow is under WP-2.3 acceptance. Existing hosts without a policy
retain the legacy API. It requires an Android API 33+ arm64 host and the default
application process.

## Host identity

Build with `build android --strategy bytecode --host-policy policy.json` and the
usual baseline-store/public-key options. Policy is compact, sorted-key JSON with
string values and no trailing newline. Its exact fields are:

| Field | Meaning |
| --- | --- |
| schema | `1` |
| application_id / version_code | Actual Android package and version code |
| channel / flavor | Signed distribution scope; use `default` for no flavor |
| abi / strategy | `arm64-v8a` / `bytecode` |
| fptc_key | Base64 raw32 patch public key, matching `--public-key` |
| root_key | Base64 raw32 independent trust-update root public key |
| keys | Sorted comma-separated `id:base64-raw32` publishing keys, max 32; `-` means none |

Only public keys belong here. Keep the root seed offline. Use separately generated
`keys init` directories for patch, publisher and trust root roles.

The CLI places the policy in the native APK, verifies its packaged bytes, and
binds its SHA256 to a schema-3 baseline/v2 fingerprint. Policy changes require a
new host APK and matching baseline. Schemas 1/2 keep their existing fingerprints.
The APK fixes the scope and FPTC key; Dart init/saveConfig cannot replace them.

## Device flow

Fetch with `FlutterPatcher.fetchSignedManifest(httpsUrl)`, then pass the returned
carrier to `applySignedManifest`. Fetching/parsing alone is not authentication.
Native verifies the exact signed envelope, saves its authorization, downloads the
payload and rechecks current authorization before committing. The result reports
`publish` or `withdraw`; installation takes effect at the next cold start.

Read signed responses directly, not through the legacy unsigned checkUpdate
helper. The publisher catalog is storage metadata: a delivery service must select
the exact signed `wire` for the requested scope. Never turn catalog fields into a
new unsigned response. HTTPS redirects and URL user-info are rejected. Signed
response bodies are limited to 24 KB; payloads use the signed size and a 120-second
read deadline.

In this mode bare applyPatch/applyPatchBytes and legacy SO loading are rejected.
Authenticated SO delivery is not implemented. SO remains available in legacy
hosts. There is no automatic downgrade on authentication failure.

## Root-authorized publication key changes

`trust sign --fields fields.json --root-public public-file --root-private seed-file
--out new-wire.json` signs a complete replacement publication key set. Fields are
the seven manifest scope strings plus `schema=1`, a strictly increasing decimal
`revision`, and `keys` in the policy format above. Signing domain is
`flutter_patcher.trust.v1\n`; publication signatures cannot authorize key changes.

`trust publish --wire new-wire.json --root-public public-file --store URI` uses a
dedicated per-scope store namespace and conditionally replaces `trust.json`. It
verifies the previous document before checking scope/revision. Identical retries
are allowed; conflicting concurrent updates require a reread. It never accepts a
private key. S3 credentials use the existing environment/profile chain.

The device fetches the document with the same bounded carrier API, then calls
`updatePublicationTrust`. Removal rejects in-flight installations and candidates
at their next boot. A running module is not hot-unloaded. Only a later root-signed
document can restore a removed key. Keep overlap during ordinary key rotation;
use removal for compromise. Changing the FPTC key or root itself requires a new
host. Losing the root seed prevents future trust updates; root compromise requires
host migration rather than trusting a recovery signed by that same root.

## Persistence and delivery limits

Authorization/trust watermarks live in no-backup storage and survive manual
rollback. Missing/corrupt initialized state rejects candidates. Withdrawal is
persisted before candidate cleanup; old files cannot resurrect it. A newer
publication does not itself revoke a still-authorized older running candidate.

Clearing application data removes local replay history. Offline devices cannot
learn new withdrawals or key revocations. These are explicit limits, not claims
of rollback-resistant hardware storage.

For private R2/S3 delivery, `publish` requests may supply `download_url` instead
of `public_base_url`. It must point to the operation's exact immutable object
path; the signature covers its entire query. Short-lived presigned URLs expire
and must be refreshed through a new manifest revision. Treat them as credentials:
keep receipts/catalog access restricted and do not copy URLs into diagnostics.
