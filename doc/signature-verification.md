# Android signature verification

Both signature paths use the lightweight Ed25519 API from the pinned Android
dependency `org.bouncycastle:bcprov-jdk18on:1.85.2` (Bouncy Castle's MIT license).
No global JCA provider is registered or replaced, and no Dart dependency is added.
Release R8 can remove unused library code.
The current standard acceptance APK grows by 1,262,855 bytes (about 1.26 MB);
most of that is Bouncy Castle resource data that R8 does not remove. This is a
measurement of the acceptance host, not a universal size guarantee. Verification
also needs a message buffer of `FPTC size - 64` bytes; peak memory still needs
device acceptance against the supported maximum patch size.

Android's `KeyFactory.getInstance("Ed25519")` can select AndroidKeyStore, whose
`generatePublic(X509EncodedKeySpec)` does not import an external public key.
An API-level check alone does not establish that this operation is supported.
The bundled verifier avoids that provider selection entirely.

The formats stay unchanged:

- Bytecode: the APK contains a raw 32-byte public key. The FPTC signature covers
  bytes `[0,82)` followed by `[146,end)`; the 64-byte signature occupies `[82,146)`.
  This is pure Ed25519, not Ed25519ph. The verifier allocates one bounded buffer
  for that concatenation after checking the envelope length and payload hash.
- Legacy SO: the public key is RFC 8410 Ed25519 SubjectPublicKeyInfo DER encoded
  as Base64, and the signature covers the lowercase MD5 hex text in UTF-8.
  The DER encoding must have absent algorithm parameters and exactly 32 key bytes.

Invalid lengths, malformed public keys, small-order keys and invalid signatures
are rejected. The bytecode API 33 minimum and the legacy `strictSignature`
policy below API 33 are unchanged.

`Ed25519VerifierTest` tests RFC 8032 and desktop interoperability. The Android
instrumentation test `Ed25519DeviceTest` exercises the production FPTC and legacy
verifiers on a device, including wrong keys, tampering and repeated verification.
Run the plugin's `connectedDebugAndroidTest` task from a Flutter Android host with
an authorized API 33+ device. JVM-only tests cannot establish Android compatibility.
