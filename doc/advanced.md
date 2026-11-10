# Advanced Operations

**English** | [简体中文](advanced-zh.md)

> Sign with a key that stays in a KMS, sign in CI without a key store, stop signing, build a host from your own policy file, publish to S3, and let your own server choose the patch file for each device and the app install it.

You have the flow from the [Production Deployment Guide](production-playbook.md) running and need one of these less common setups. Each section is one task: what it needs, what to do, and how to check it. Every option mentioned here is described in the [CLI Reference](cli.md).

## Signing with a KMS or Signing Service

**Goal**: sign patch files with a key that never leaves a KMS, Vault, an HSM or a password manager.

**Before**: the service holds an Ed25519 key and signs with pure Ed25519 (RFC 8032, not Ed25519ph), because the device verifies signatures as pure Ed25519.

**Do**:

1. Put the service's public key (the raw 32 bytes in base64) and the signing command in `flutter_patcher.yaml`:

   ```yaml
   trust:
     patch: <base64 Ed25519 public key>
     enabled: true
   signing:
     command: my-signer --key fp-patch
   ```

   The command runs through `/bin/sh -c` (a batch file on Windows). It receives the bytes to sign on stdin, and must print one base64 Ed25519 signature (64 bytes) on stdout, exit with `0`, and finish within 60 seconds. Its environment holds `FLUTTER_PATCHER_SIGN_ROLE=patch` and `FLUTTER_PATCHER_SIGN_PUBLIC_KEY=<the public key>`, so one command can pick the right key for several projects; `FLUTTER_PATCHER_KEYS` is removed from it.

2. Build the host again. Hosts built from then on accept only files signed by this key, because a host keeps the key it was built with.

**Check**: `dart run flutter_patcher keys status` prints `"private_key":"signing.command"`, and `publish` prints `"signed":true`.

- `--key-file` and `FLUTTER_PATCHER_KEYS` come before `signing.command` in [Where the private key comes from](cli.md#where-the-private-key-comes-from), so leave both unset on machines that sign with the command.
- Every signature is verified against `trust.patch` before it is used. A command that cannot start, exits non-zero, prints no 64-byte base64 signature, takes over 60 seconds or signs with another key stops `patch` or `publish` with `SIGNER_COMMAND_FAILED`.

## Keys in CI

**Goal**: let a CI job sign patch files without a key store on the runner.

**Do**:

1. On a machine that has the key, print the key bundle as one line and store it as a CI secret:

   ```bash
   dart run flutter_patcher keys export --base64
   ```

2. Expose the secret to the job as the environment variable `FLUTTER_PATCHER_KEYS`, then patch and publish with `--yes`:

   ```bash
   dart run flutter_patcher patch android
   dart run flutter_patcher publish --yes   # Without a terminal and without --yes, publish only previews
   ```

**Check**: `keys status` in the job prints `"private_key":"FLUTTER_PATCHER_KEYS"`; `publish` prints `"status":"published"` and `"signed":true`.

- A bundle that holds another key fails with `KEYS_MISMATCH`, because the first source that is present is never skipped.
- A key bundle written by flutter_patcher 1.0 works too; only its patch key is used.
- To add the bundle to a runner's key store instead, pipe it into `keys import -`.

## Stop Signing

**Goal**: let hosts built from now on accept unsigned patch files.

**Do**: set `trust.enabled` back to `false` in `flutter_patcher.yaml`, then build the host again.

**Check**: `build` prints `WARNING: UNSIGNED`.

- Signed hosts already shipped are not affected: each of their patches still needs the original private key, because a host keeps the public key it was built with.

## Custom Host Policy

**Goal**: build a host from a policy file you write, instead of the one `build` derives from the project, `flutter_patcher.yaml` and its options.

**Do**:

1. Write the policy: a JSON object whose values are all strings, with exactly these fields:

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

2. Build with it:

   ```bash
   dart run flutter_patcher build android --host-policy policy.json
   ```

| Field | Requirement |
|---|---|
| `schema` | `2`. A flutter_patcher 1.0 policy (`"schema": "1"`) is accepted: its `fptc_key` is kept, and its `root_key` and `keys` are ignored |
| `strategy` | `bytecode` or `so`; `so` only with `abi` `arm64-v8a`, because iOS hosts load bytecode only |
| `abi` | `arm64-v8a` for `build android`, `ios-arm64` for `build ios` |
| `application_id` | The app's application id (iOS bundle id), such as `com.example.app` |
| `version_code` | The app's build number, from 1 to 2100000000; equal to `--version-code` when that is given |
| `flavor`, `channel` | 1 to 64 letters, digits and `_`, because both become part of the patch file name; `flavor` equal to `--flavor` (default `default`) |
| `fptc_key` | The patch public key in base64, or `-` for an unsigned host. It alone decides whether the host is signed; `trust.patch` in `flutter_patcher.yaml` is not read |

- With `--host-policy`, `build` takes `strategy`, `channel` and `application_id` from the file; `--strategy`, `--channel` and `--application-id` are not read.
- A file that breaks these rules, or disagrees with `--flavor` or `--version-code`, fails with `BUILD_CONFIG_INVALID` before the build starts.
- When the built app's application id or build number differs from the policy, `build` fails with `BUILD_APK_INVALID` (`BUILD_IPA_INVALID` on iOS), because the policy is written into the package and must describe it.

## Publishing to S3

**Goal**: have `publish` write patch files to an S3 bucket, or to a service with the S3 API such as Cloudflare R2.

**Before**:

- The AWS CLI (`aws`) is installed, and its own configuration holds the credentials for the bucket. The store address carries none: `publish` rejects a `store` with user info, a query or a fragment with `PUBLISH_CONFIG_INVALID`.
- The service supports conditional writes, `put-object` with `--if-none-match` and `--if-match`, because `publish` replaces a file only when it is unchanged since it was read.
- The role can get and put objects under the prefix and has `s3:ListBucket`, because without it a missing object answers `403` instead of `NoSuchKey`, and `publish` fails with `PUBLISH_STORE_UNAVAILABLE`.

**Do**: set the store in `flutter_patcher.yaml` to a dedicated prefix of the bucket, and `url` to the address that serves that prefix:

```yaml
store: s3://my-bucket/my-app
url: https://cdn.example.com/my-app
```

For a service other than AWS, set `FLUTTER_PATCHER_S3_ENDPOINT` to its HTTPS endpoint.

**Check**: after `publish`, the bucket holds `my-app/<fileName>`, such as `my-app/7-arm64-v8a.fptc`, and `curl -sI https://cdn.example.com/my-app/<fileName>` returns `200`.

- The store must be a prefix below the bucket root, and each segment may use only letters, digits, `_` and `-`; anything else fails with `PUBLISH_STORE_INVALID`.
- When two publishes run at once, one fails with `PUBLISH_CONFLICT`, because the file changed between its read and its write. Run `publish` again.
- What the address at `url` must answer is listed in [Storage requirements](cli.md#storage-requirements).

## Custom Delivery from Your Own Server

**Goal**: your server decides which device receives which patch file, and the app installs it with `applyPatchBytes` or `applyPatchFile`. The file can also come through another channel, such as a CDN, a push message, a file bundled with an app update or one the user picks; it installs the same way.

These APIs need flutter_patcher 1.1.0 or newer. Hosts built with flutter_patcher 1.0.0 are patched with flutter_patcher 1.0.0+1; see [Upgrading from 1.0](upgrading.md).

**Do**:

1. Keep the patch files on the server: the `<fileName>` file `publish` writes at the store root, or the file `patch` prints as `file`. A withdrawal file is kept and delivered the same way; see [Delivering a rollback](production-playbook.md#delivering-a-rollback).
2. Have the app send the fields of `FlutterPatcher.patchTarget` with its request, and answer with the file to install, or with nothing:

   | Field | Use on the server |
   |---|---|
   | `fileName` | Which host build the device is; the name of its file |
   | `fingerprint` | Tells builds apart when one file name belongs to several builds |
   | `acceptedSeq` | The highest sequence the device accepted; only a file numbered above it installs |
   | `versionCode`, `flavor`, `channel`, `abi`, `strategy`, `signed` | Further facts for choosing, such as a staged rollout |

3. Have the app install the file the server returns:

   ```dart
   import 'dart:io';

   import 'package:flutter/foundation.dart';
   import 'package:flutter_patcher/flutter_patcher.dart';

   /// Asks your own server for this host's patch file and installs it.
   Future<void> updateFromMyServer() async {
     final target = await FlutterPatcher.patchTarget; // Who this host build is.
     final uri = Uri.https('api.example.com', '/patches', {
       'file': target.fileName,
       'fingerprint': target.fingerprint,
       'after': '${target.acceptedSeq}',
     });
     final client = HttpClient();
     try {
       final response = await (await client.getUrl(uri)).close();
       if (response.statusCode == HttpStatus.noContent) return; // Nothing newer.
       if (response.statusCode != HttpStatus.ok) {
         throw HttpException('HTTP ${response.statusCode}', uri: uri);
       }
       final bytes = await consolidateHttpClientResponseBytes(response);
       // Verifies and installs the file for the next cold start.
       final result = await FlutterPatcher.applyPatchBytes(bytes);
       if (!result.ok) {
         debugPrint('patch rejected: ${result.error?.name} ${result.message}');
       }
     } finally {
       client.close();
     }
   }
   ```

4. Optional: to skip downloading a file the device would reject, have the app read the file's first 146 bytes and pass them to `FlutterPatcher.inspectPatch`. `fresh` is `true` only for a patch or withdrawal of this host numbered above `acceptedSeq`.

**Check**: `applyPatchBytes` returns `ok: true`, `FlutterPatcher.currentVersion` is the file's `seq`, and after the next cold start `lastBootDiagnostic.status` is `patched`.

- On a signed host the server and the transport need not be trusted, because the device installs only files signed by the host's patch key. On an unsigned host, whoever can change the file the app receives can run code in it, so the request must go over HTTPS to a server you trust. Signing is fixed when the host is built; see [Turn On Signing](production-playbook.md#3-turn-on-signing).
