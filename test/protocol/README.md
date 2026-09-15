# Signed manifest v1 vectors

`manifest-v1.json` is shared by CLI signing-codec tests, Dart untrusted-envelope
tests, and Android signature/policy tests. No production update path uses this
protocol yet. Native returns a proposed state transition without persisting it.

Regenerate using Python with `cryptography` installed:

```text
python test/protocol/generate_vectors.py
```

The seed is the public RFC 8032 test seed. Never use it to publish real patches.
`parse_valid` tests the canonical payload; `envelope_valid` tests only transport
encoding, not authentication. `verify_valid` includes native signature, trusted
scope, minimum plugin version, revision and sequence policy. A bad signature can
therefore have a valid envelope and payload. `state` is a trusted prior snapshot,
scoped by the host, not data supplied by a server.

The signing message is UTF-8 `flutter_patcher.manifest.v1\n` followed by the exact
canonical payload bytes. The payload is sorted, compact, flat ASCII JSON with
string values. The envelope is compact JSON in payload/signature order with
canonical padded Base64 values. Unknown fields, repeated keys and alternative
encodings are rejected. The local design specification resides under `plan/`;
that directory remains excluded from version control.

From the CLI package directory run `dart test test/publish_protocol_test.dart`.
From the repository run `flutter test test/signed_manifest_test.dart`.
Android runs `PublishManifestTest` in the normal plugin JVM suite; set
`WP21_VECTORS` to an absolute vector path if the test host is outside the repo.
