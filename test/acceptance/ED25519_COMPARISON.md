# Ed25519 dependency replacement — 2026-09-11

Replaced bcprov 1.85.2 with a verification-only Kotlin implementation using
platform BigInteger and SHA-512. Signing formats and strict public-key validation
remain unchanged. No global provider or resource exclusion is used.
Implementation details: [android/ED25519.md](../../android/ED25519.md).

Both runs used HONOR MEY-AN00, Android 16/API 36, serial AF2Q025C05004551.
The Kotlin run rebuilt current source, APK, patches and all corpus cases before
device testing, using the documented `rebuild_regression.py --config
test/acceptance/regression-config.example.json` entry point. No device settings
were changed and no emulator was used.

| Signal | Bouncy Castle baseline | Kotlin replacement |
| --- | ---: | ---: |
| Standard APK bytes | 26,199,353 | 24,936,498 |
| Device matrix | 31/31 | 31/31 |
| Instrumentation | 4/4 | 4/4 |
| JVM test methods | 28/28 | 30/30 |
| Lean median added startup, ms | 35 | 21.5 |
| Whole median added startup, ms | 255 | 244 |

APK reduction: 1,262,855 bytes (about 1.20 MiB, 4.82%). The new APK has none
of the five `org/bouncycastle/` resources present in the baseline. Its DEX is
597,540 bytes versus 627,460 bytes. No global packaging filter was added.

The added JVM methods exercise all 151 Wycheproof vectors (88 valid, 63 invalid)
and JDK signatures across ten message lengths. These are additional checks,
not a replacement for the existing RFC/OpenSSL fixtures or device matrix.
All test failures, errors and skipped counts are zero. The device case IDs and
order exactly match the freshly generated corpus. The complete command exited 0.

Timing is a single same-device comparison with ten baseline and ten patch
samples per valid case. It does not establish a speedup. Whole startup still
exceeds the 85 ms budget; functional success is not full M1 acceptance.

## Local evidence

All paths below are relative to the repository root:

- BC: `.dart_tool/flutter_patcher/regression/20260911-193009-71ac077d/result.json`
- Kotlin: `.dart_tool/flutter_patcher/regression/20260911-195036-57fb6769/result.json`
- Matrix: same Kotlin directory, `matrix/result.json`
- Instrumentation: same Kotlin directory, `instrumentation.txt`
- Native results and build receipt: same Kotlin directory, `inputs/`

Kotlin source receipt SHA256:
`722a0de1b6661dff359a5b65f33b4376c7211c5e3350020178b90882720b8329`.
The changed build file, verifier, verifier tests and vector fixture were checked
against that receipt after the run. Documentation was added after the snapshot.

Kotlin result SHA256:
`15e701fe288ea83f5c8a14cc7d851e87072e738cfbeddf0100d3bf9a9890793f`.
Kotlin matrix SHA256:
`c31b7f9414adfb6ae4ddb2db4ffa9c2fef8268020863b27d14ef6821788fdb40`.

The build archive and raw device logs remain local; this tracked report records
their identities. No Git push or publication was performed.
