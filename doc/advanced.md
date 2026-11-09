<!-- ========================================== -->
<!-- doc/advanced.md (English)                  -->
<!-- ========================================== -->

# Advanced Operations

**English** | [简体中文](advanced-zh.md)

Operations you need only occasionally. Everyday setup and publishing are in the [Production Deployment Guide](production-playbook.md).

## Signing with a KMS or Signing Service

**Goal**: sign patch files with a key that never leaves a KMS, Vault, an HSM or a password manager.

**Before**: the service holds an Ed25519 key and can sign with pure Ed25519 (RFC 8032; not Ed25519ph).

**Do**:

1. Put its public key, the raw 32 bytes in base64, and the command in `flutter_patcher.yaml`:

   ```yaml
   trust:
     patch: <base64 Ed25519 public key>
   signing:
     command: my-signer --key fp-patch
   ```

   The command receives the bytes to sign on stdin and prints the base64 64-byte signature on stdout, exiting 0 within 60 seconds. It runs with `/bin/sh -c` (on Windows from a batch file through `cmd.exe`), with `FLUTTER_PATCHER_SIGN_ROLE=patch` and `FLUTTER_PATCHER_SIGN_PUBLIC_KEY=<trust.patch>` set and `FLUTTER_PATCHER_KEYS` removed from its environment.

2. Build the host again: hosts built from now on accept only files signed by this key.

**Check**: `dart run flutter_patcher keys status` shows `"private_key":"signing.command"`, and `publish` prints `"signed":true`.

`--key-file` and `FLUTTER_PATCHER_KEYS` come before `signing.command`; unset them on machines that should use the command. Every signature is verified against `trust.patch` before use: a command that fails, times out or signs with another key stops `publish` with `SIGNER_COMMAND_FAILED`.

## Keys in CI

**Goal**: let a CI job sign without a key store.

**Do**:

1. On a machine that has the key, print the key bundle as one line and store it as a CI secret:

   ```bash
   dart run flutter_patcher keys export --base64
   ```

2. Expose the secret to the job as the environment variable `FLUTTER_PATCHER_KEYS`, and publish with `--yes`. Without a terminal, `publish` without `--yes` only previews:

   ```bash
   dart run flutter_patcher publish --yes
   ```

**Check**: `keys status` in the job shows `"private_key":"FLUTTER_PATCHER_KEYS"`.

A bundle that holds another key fails with `KEYS_MISMATCH`; it is never skipped for the next source. A 1.0 key bundle works too: only its patch key is used. To put the bundle into a key store instead, run `keys import -` with it on stdin.

## Custom Host Policy

**Goal**: build a host from a policy file you write, instead of the one `build` derives from the project.

**Do**: write the policy, a JSON object whose values are all strings, with exactly these fields:

```json
{
  "schema": "2",
  "strategy": "bytecode",
  "abi": "arm64-v8a",
  "application_id": "com.example.app",
  "version_code": "7",
  "flavor": "default",
  "channel": "production",
  "fptc_key": "<base64 Ed25519 public key, or - for an unsigned host>"
}
```

and build with it:

```bash
dart run flutter_patcher build android --host-policy policy.json
```

- `abi` is `arm64-v8a` (`build android`) or `ios-arm64` (`build ios`, where `strategy` must be `bytecode`).
- The policy must agree with the build: its `flavor` with `--flavor` (default `default`) and its `version_code` with `--version-code` when given, or `build` fails with `BUILD_CONFIG_INVALID`. Its `application_id` and `version_code` must be the app's application id (iOS bundle id) and build number: the device checks them against the installed app.
- `fptc_key` in the file decides whether the host is signed; `trust.patch` in `flutter_patcher.yaml` is not used.
- A flutter_patcher 1.0 policy file (`"schema": "1"`) is accepted: its `fptc_key` is kept, `root_key` and `keys` are dropped.

Anything else fails with `BUILD_CONFIG_INVALID`.

## Publishing to S3

**Goal**: have `publish` write patch files straight to an S3 bucket, or a service with the S3 API.

**Before**: the AWS CLI (`aws`) is installed and has credentials for the bucket, from its usual configuration; the store address never contains credentials. The service supports conditional writes (`If-None-Match` and `If-Match` on `PutObject`).

**Do**: set the store in `flutter_patcher.yaml` to a dedicated prefix of the bucket:

```yaml
store: s3://my-bucket/my-app
url: https://cdn.example.com/my-app
```

For an S3-compatible service other than AWS, set `FLUTTER_PATCHER_S3_ENDPOINT` to its endpoint URL.

**Check**: after `publish`, the bucket holds `my-app/<fileName>.fptc`, for example `my-app/7-default-production-arm64-v8a.fptc`, and `https://cdn.example.com/my-app/<fileName>.fptc` serves it.

- The prefix is required (not the bucket root), and each of its segments uses only letters, digits, `_` and `-`.
- `publish` reads the file there first and writes only when it is unchanged since: two publishes at once fail one of them with `PUBLISH_CONFLICT`; publish it again.

## Serving Patch Files from Your Own API

**Goal**: devices get patch files from your own backend, which decides who gets which file, instead of from a fixed URL.

**Do**:

1. On the server, keep the files `publish` writes (`<fileName>.fptc` at the store root), or take each from a `patch` output directory.
2. In the app, ask your server for this host's file and hand it to the plugin:

   ```dart
   final target = await FlutterPatcher.patchTarget;
   // Your own request: send what the server needs to pick a file.
   final bytes = await myApi.fetchPatch(
     file: target.fileName,          // e.g. 7-default-production-arm64-v8a.fptc
     acceptedSeq: target.acceptedSeq, // highest sequence this device took; 0 before any
   );
   if (bytes != null) {
     final result = await FlutterPatcher.applyPatchBytes(bytes);
     if (!result.ok) report(result.error, result.message); // your own reporting
   }
   ```

   A file already on disk, such as one bundled with the app or downloaded by your own code, goes to `applyPatchFile(path)`; the plugin leaves that file in place.

3. To skip downloading a file the device would not take, read its first 146 bytes and ask `FlutterPatcher.inspectPatch(header)`: `fresh` is true only for a newer patch or withdrawal of this host.

**Check**: `applyPatchBytes` returns `ok: true`, `FlutterPatcher.currentVersion` is the file's sequence, and after the next cold start `lastBootDiagnostic` has `status` `patched`.

- Native code verifies the whole file whichever way it came; `inspectPatch` does not replace that.
- On a signed host your server and its transport need not be trusted. On an unsigned host, whoever can change the file your app receives can run code in it, so the request must use HTTPS to a server you trust.
- A withdrawal file goes through `applyPatchBytes` the same way.
- Other `PatchTarget` fields: `versionCode`, `flavor`, `channel`, `abi`, `strategy`, `fingerprint`, `signed`. Full API: [API Reference](api-reference.md).
