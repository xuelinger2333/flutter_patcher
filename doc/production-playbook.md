# Production Playbook

Best practices and field notes for shipping flutter_patcher patches in production.

---

## Stage your rollout

Don't ship a patch to 100% on day one. A typical ramp:

```text
1% → 5% → 20% → 50% → 100%
```

Watch crash rate, boot failure rate, and key business metrics at each stage.

---

## Report boot diagnostics

Report `lastBootDiagnostic` to your analytics pipeline:

```dart
final diag = await FlutterPatcher.lastBootDiagnostic;

if (diag != null && !diag.isHealthy) {
  // Replace with your analytics SDK: Firebase Analytics / Sentry / your own pipeline.
  analytics.report('patch_dropped', {
    'status': diag.status.name,
    'patch_version': diag.patchVersion,
    'crash_count': diag.crashCount,
    'message': diag.message,
  });
}
```

If the same patch triggers `droppedCircuitBreaker` repeatedly in a short window, the server should automatically stop delivering it.

---

## Keep release records

Track each patch with at least:

| Field | Example |
|---|---|
| Patch version | `1.0.0-h1` |
| Target APK `versionCode` | `100` |
| ABI | `arm64-v8a` |
| Flavor | `production` |
| MD5 | `0123456789abcdef...` |
| Signature | (if shipped) |
| Release time | `2025-07-15T10:00:00Z` |
| Rollout percentage | `20%` |
| State | ramping / full / rolled back |

---

## Compress patch downloads

The entries of a bytecode patch (`.fptc`) are stored uncompressed, so the
device can check and load them without unpacking. On the wire they compress
well: a 2.27 MB lean patch is 0.83 MB with gzip. Turn on gzip (or let your CDN
do it) for `.fptc` responses.

The client asks for gzip and decodes it before any check: the size and SHA-256
in the signed manifest apply to the decoded file, exactly as without
compression. Keep publishing the original file; do not upload a pre-compressed
copy under the same name unless your server marks it with
`Content-Encoding: gzip`, or the digest check will reject it.

---

## Plan for emergency rollback

An emergency rollback only requires the update endpoint to stop returning the offending patch version. Devices that already tripped crash protection have rolled back locally and will refuse to apply the same problematic patch again.

---

## Multi-ABI distribution

The server must distribute a different `patch.zip` per ABI. Each patch embeds one `lib/<abi>/libapp.so`. The client reports its ABI via `FlutterPatcher.deviceAbi`.

Recommended server key: `ABI × flavor × versionCode`.

---

## Multi-flavor distribution

Different flavors typically have different configs, package names, resources, and business logic. Never share a patch across flavors. The server should shard by `flavor × ABI × versionCode`.

---

## Field notes

_This section collects real-world tips from production users. If you have experience to share, [open an issue](https://github.com/xuelinger2333/flutter_patcher/issues) — we'll add it here._
