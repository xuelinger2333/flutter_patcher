# Native authenticated-byte bootstrap — 2026-09-11

Implementation commit: `e009aee`. Standalone experiment sources: `4e30441`.
Design: [authenticated byte transport](../../doc/authenticated-bootstrap-bytes-design.md).

## Change under test

Android returns the same local ByteArray that passed envelope authentication and
the stored-candidate digest check. Dart accepts only transportVersion 1 plus a
Uint8List and nonempty attempt. It no longer reopens a path or computes the
payload/full-file SHA again. Archive CRC, manifest entry digests, identity checks,
entry contract and boot transaction state remain unchanged.

The offline file verifier still performs both hashes. Profile schema 2 makes
removed work explicit without interpreting missing mandatory counters as zero.
The local SPEC was updated; it is ignored by Git, so the tracked design and this
report preserve the protocol change too.

## Local validation

- 36 Dart tests passed: bootstrap behavior, typed-data snapshot surviving source
  file replacement/array mutation after codec encoding, old protocol and bad
  response rejection, expired attempt and late response, CRC fixtures, binding
  ownership and the archive/entry subset of the previously authenticated corpus.
  The reused corpus is unit-test input, not current-build device evidence.
- Six Python checks passed, including profile schema and budget boundaries.
- Static analysis found no errors/warnings in inspected code; style infos remain.
- Historical schema-1 analysis still reproduces the previous 65.144/252.631 ms
  bootstrap means. No old result file was overwritten.

## Frozen rebuild

Run: `.dart_tool/flutter_patcher/regression/20260911-221130-cc74ea2d/`.
Source SHA256: `2bfd64c1a3c7b885d3500ac3b8cf9b62bddf29655a5dbfbb1898ce3bcfcd7b22`.
Build/device validation is in progress; no current-version acceptance or budget
verdict is claimed at this checkpoint.

## Probe interpretation limits

The separate test APK reproduces the same codec, worker/main reply pattern and
frozen envelope verifier; it never resets processClaimed or mutates patch state.
It compares pre-binding and post-frame calls with empty, byte and verified-byte
responses. It uses an ordinary app entry, without the full production host's
initialization and module loading, so it is a phase-sensitivity experiment, not
an exact replay of the production bootPayload transaction.

Payload read in this probe is from a packaged asset; native operation time also
includes that read and, for verified mode, test metadata parsing. Compare the
outside-Java residual as well as total latency; total validation work is not
expected to vanish after the first frame. First verification also includes lazy
crypto initialization. Dart verifies returned byte digests outside the timed span.

RSS and high-water RSS include the process, framework and post-timing digest
work; they are not isolated codec allocation measurements. The single ~2 MB
payload does not establish safe near-limit 320 MiB transfers or a worst-case
memory bound. No transport limit was silently changed.
