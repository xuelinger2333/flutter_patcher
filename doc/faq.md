<!-- ========================================== -->
<!-- doc/faq.md (English)                       -->
<!-- ========================================== -->

# Frequently Asked Questions (FAQ)

**English** | [简体中文](faq-zh.md)

### Why do patches require a cold start to take effect?

To guarantee runtime state consistency. Active code and in-memory objects cannot be safely swapped out mid-execution. Once a patch is downloaded and verified, the app continues running the existing code until the next process launch, ensuring old and new code paths are never mixed within a single session. See [How It Works: Life on the device](architecture.md#life-on-the-device).

### Can an app built with standard `flutter build` receive patches?

**No.** Patches can only be applied to baseline releases built with `flutter_patcher build`, which bundles the custom runtime engine and your embedded verification public keys (see [How It Works: The host](architecture.md#the-host-an-app-that-accepts-patches)). If you already have a standard build live in the store, you must rebuild and ship a new store release using `flutter_patcher build` first.

### Does the bytecode strategy slow down the app?

**Unpatched apps run at full native AOT speed, identical to a standard Flutter release build. When patched, only the modified functions are executed by the bytecode interpreter—all unchanged code continues to run as compiled native machine code.**

For typical UI and business logic changes, the performance difference is imperceptible. However, if a patch modifies compute-heavy hot loops, those specific functions will run slower than native code. On Android, if raw compute performance inside a patch is critical, you can switch to the `so` strategy at the cost of a larger patch bundle size. See [How It Works: Two patch strategies](architecture.md#two-patch-strategies).

### What happens when I upgrade my Flutter SDK version?

Upgrading the Flutter SDK requires running `build` and shipping a new store release. **Patches cannot cross Flutter SDK versions**—to continue patching an older live release, you must generate those patches using the exact Flutter version that built that baseline release (keep the older SDK cached in CI or pass `--flutter-sdk`).

### What happens to installed patches when a user updates the app from the store?

**They are automatically invalidated and cleaned up.** Every patch is strictly bound to the baseline `versionCode` it was built against. Once a user upgrades to a newer store release, old patches are ignored. If the new release also needs a hotfix, publish a new patch targeting the new version.

### Can I maintain and patch multiple live app versions simultaneously?

**Yes.** Each store release has its own isolated baseline snapshot and patch sequence. To patch an older release, check out its source tag, apply the fix, and run `patch --version-code <target_build_number>`. See [Production Playbook: Release Workflow](production-playbook.md#release-workflow).

### Can patches be tampered with or forged if my CDN is compromised?

**No.** The on-device runtime only accepts patches that are cryptographically signed by your private key and match the exact baseline fingerprint (`scope`) of the installed app. Even if your storage bucket or CDN is compromised, an attacker cannot forge a valid patch without your private key or replay a patch meant for a different version. See [How It Works: Security model](architecture.md#security-model). The private keys live outside your project, in your key store, CI secrets or signing service; back them up with `keys export` (see [Production Playbook: Keys on Machines and CI](production-playbook.md#keys-on-machines-and-ci)).

### What if a buggy patch causes the app to crash on startup?

**The SDK automatically rolls back to the bundled baseline build upon detecting a startup failure and blacklists the faulty patch locally**, preventing crash loops. You should immediately [withdraw the patch](production-playbook.md#withdrawing-a-patch) or publish a fixed patch so other devices do not install it. See [Crash Protection](crash-protection.md).

### Do I need to build and run a custom backend server?

**No.** Both patches and manifests are static files. Any static file hosting service served over HTTPS—such as AWS S3, Cloudflare R2, Alibaba Cloud OSS or Google Cloud Storage behind a CDN—works out of the box. See [Production Playbook: Configuring Storage](production-playbook.md#configuring-storage).

### Are x86 emulators or 32-bit Android devices supported?

**No.** On Android, only `arm64-v8a` is supported (which covers virtually all modern Android phones in active use and aligns with Google Play's 64-bit requirement).

### Do app stores allow over-the-air hotfixing?

Policies vary across distribution channels and regulated industries (such as finance, healthcare, or kids' apps), some of which restrict downloading executable code. `flutter_patcher` provides the technical mechanism; you are responsible for ensuring compliance with your target store guidelines and industry regulations before deploying.

### Why does running `patch` on Windows report that every single file changed?

This happens when Git converts line endings to `CRLF` on Windows, causing byte-level diffs against a baseline built with `LF` line endings. See the fix in [Troubleshooting: Common Issues](troubleshooting.md#changed-a-single-line-of-dart-but-every-file-shows-as-modified-or-fails-with-patch_native_change).