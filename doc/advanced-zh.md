# 进阶操作

[English](advanced.md) | **简体中文**

> 用留在 KMS 中的密钥签名，在没有密钥库的 CI 中签名，停止签名，用自己写的策略文件构建宿主，发布到 S3，以及让自己的服务端为每台设备选择补丁文件并由 App 安装。

你已经按[生产部署](production-playbook-zh.md)跑通了流程，现在需要下面某一种不常见的配置。每一节是一个任务：需要什么、怎么做、怎么验证。本页提到的每个选项见 [CLI 参考](cli-zh.md)。

## 用 KMS 或签名服务签名

**目标**：用一把从不离开 KMS、Vault、HSM 或密码管理器的密钥为补丁文件签名。

**前提**：该服务持有一把 Ed25519 密钥，并以纯 Ed25519（RFC 8032，不是 Ed25519ph）签名，因为设备按纯 Ed25519 验证签名。

**步骤**：

1. 把该服务的公钥（原始 32 字节的 base64）和签名命令写入 `flutter_patcher.yaml`：

   ```yaml
   trust:
     patch: <base64 Ed25519 公钥>
     enabled: true
   signing:
     command: my-signer --key fp-patch
   ```

   该命令通过 `/bin/sh -c` 运行（Windows 上通过批处理文件）。它从 stdin 读取待签名的字节，必须在 stdout 输出一个 base64 的 Ed25519 签名（64 字节），以 `0` 退出，并在 60 秒内完成。它的环境变量中有 `FLUTTER_PATCHER_SIGN_ROLE=patch` 和 `FLUTTER_PATCHER_SIGN_PUBLIC_KEY=<公钥>`，所以一条命令可以为多个项目选择对应的密钥；`FLUTTER_PATCHER_KEYS` 不会传给它。

2. 重新构建宿主。此后构建的宿主只接受这把密钥签名的文件，因为宿主保留构建时写入的公钥。

**验证**：`dart run flutter_patcher keys status` 输出 `"private_key":"signing.command"`，`publish` 输出 `"signed":true`。

- 在[私钥从哪里来](cli-zh.md#私钥从哪里来)的顺序中，`--key-file` 和 `FLUTTER_PATCHER_KEYS` 排在 `signing.command` 之前，所以在用该命令签名的机器上不要设置这两项。
- 每个签名在使用前都用 `trust.patch` 验证。命令无法启动、以非零退出、没有输出 64 字节的 base64 签名、超过 60 秒或用了另一把密钥时，`patch` 或 `publish` 以 `SIGNER_COMMAND_FAILED` 失败。

## CI 中的密钥

**目标**：让 CI 任务为补丁文件签名，而 runner 上不需要密钥库。

**步骤**：

1. 在有密钥的机器上，把密钥包输出为一行，保存为 CI secret：

   ```bash
   dart run flutter_patcher keys export --base64
   ```

2. 把该 secret 以环境变量 `FLUTTER_PATCHER_KEYS` 提供给任务，然后生成补丁并用 `--yes` 发布：

   ```bash
   dart run flutter_patcher patch android
   dart run flutter_patcher publish --yes   # 没有终端且没有 --yes 时，publish 只预览
   ```

**验证**：在任务中运行 `keys status`，输出 `"private_key":"FLUTTER_PATCHER_KEYS"`；`publish` 输出 `"status":"published"` 和 `"signed":true`。

- 密钥包中是另一把密钥时报 `KEYS_MISMATCH`，因为第一个存在的来源不会被跳过。
- flutter_patcher 1.0 写出的密钥包同样可用，只使用其中的补丁密钥。
- 要改为把密钥包加入 runner 的密钥库，把它通过管道传给 `keys import -`。

## 停止签名

**目标**：让此后构建的宿主接受不签名的补丁文件。

**步骤**：在 `flutter_patcher.yaml` 中把 `trust.enabled` 改回 `false`，然后重新构建宿主。

**验证**：`build` 输出 `WARNING: UNSIGNED`。

- 已经发布的签名宿主不受影响，它们的每个补丁仍然需要原来的私钥签名，因为宿主保留构建时写入的公钥。

## 自定义宿主策略

**目标**：用自己写的策略文件构建宿主，而不是由 `build` 根据项目、`flutter_patcher.yaml` 和命令选项生成。

**步骤**：

1. 编写策略：一个所有值都是字符串的 JSON 对象，字段必须正好是以下这些：

   ```json
   {
     "schema": "2",
     "strategy": "bytecode",
     "abi": "arm64-v8a",
     "application_id": "com.example.app",
     "version_code": "7",
     "flavor": "default",
     "channel": "production",
     "fptc_key": "<base64 Ed25519 公钥；不签名的宿主填 ->"
   }
   ```

2. 用它构建：

   ```bash
   dart run flutter_patcher build android --host-policy policy.json
   ```

| 字段 | 要求 |
|---|---|
| `schema` | `2`。flutter_patcher 1.0 的策略文件（`"schema": "1"`）也被接受：保留其 `fptc_key`，忽略 `root_key` 和 `keys` |
| `strategy` | `bytecode` 或 `so`；`so` 只能与 `abi` `arm64-v8a` 搭配，因为 iOS 宿主只加载字节码 |
| `abi` | `build android` 为 `arm64-v8a`，`build ios` 为 `ios-arm64` |
| `application_id` | App 的 application id（iOS 为 bundle id），例如 `com.example.app` |
| `version_code` | App 的构建号，1 到 2100000000；传了 `--version-code` 时须与之相等 |
| `flavor`、`channel` | 1 到 64 个字母、数字和 `_`，因为两者都是补丁文件名的一部分；`flavor` 须与 `--flavor` 相等（默认 `default`） |
| `fptc_key` | base64 的补丁公钥；不签名的宿主填 `-`。宿主是否签名只由它决定，不读取 `flutter_patcher.yaml` 中的 `trust.patch` |

- 使用 `--host-policy` 时，`build` 从文件中读取 `strategy`、`channel` 和 `application_id`，不读取 `--strategy`、`--channel` 和 `--application-id`。
- 文件不符合上述规则，或与 `--flavor`、`--version-code` 不一致时，在构建开始之前以 `BUILD_CONFIG_INVALID` 失败。
- 构建出的 App 的 application id 或构建号与策略不同时，`build` 以 `BUILD_APK_INVALID`（iOS 为 `BUILD_IPA_INVALID`）失败，因为策略会写入安装包，必须与安装包一致。

## 发布到 S3

**目标**：让 `publish` 把补丁文件写入 S3 存储桶，或写入 Cloudflare R2 这类提供 S3 API 的服务。

**前提**：

- 已安装 AWS CLI（`aws`），存储桶的凭据在它自己的配置中。存储地址不带凭据：`store` 中含有用户信息、查询参数或片段时，`publish` 以 `PUBLISH_CONFIG_INVALID` 拒绝。
- 该服务支持条件写入，即带 `--if-none-match` 和 `--if-match` 的 `put-object`，因为 `publish` 只在文件自读取后没有变化时才替换它。
- 角色能读写该前缀下的对象，并拥有 `s3:ListBucket`，因为缺少它时不存在的对象返回 `403` 而不是 `NoSuchKey`，`publish` 以 `PUBLISH_STORE_UNAVAILABLE` 失败。

**步骤**：在 `flutter_patcher.yaml` 中把存储设为存储桶下的一个专用前缀，把 `url` 设为对外提供该前缀的地址：

```yaml
store: s3://my-bucket/my-app
url: https://cdn.example.com/my-app
```

AWS 以外的服务，把 `FLUTTER_PATCHER_S3_ENDPOINT` 设为它的 HTTPS 端点。

**验证**：`publish` 之后，存储桶中有 `my-app/<fileName>`，例如 `my-app/7-arm64-v8a.fptc`，并且 `curl -sI https://cdn.example.com/my-app/<fileName>` 返回 `200`。

- 存储必须是存储桶根目录之下的前缀，每一段只能使用字母、数字、`_` 和 `-`；否则以 `PUBLISH_STORE_INVALID` 失败。
- 两次发布同时运行时，其中一次以 `PUBLISH_CONFLICT` 失败，因为文件在它读取和写入之间发生了变化。重新运行 `publish`。
- `url` 所在的地址必须如何应答，见[存储要求](cli-zh.md#存储要求)。

## 由自家服务端自定义下发

**目标**：由你的服务端决定哪台设备收到哪个补丁文件，App 获取文件后用 `applyPatchBytes` 或 `applyPatchFile` 安装。文件也可以来自其他渠道，例如 CDN、推送消息、随 App 更新内置的文件或用户选择的文件，安装方式相同。

这些 API 需要 flutter_patcher 1.1.0 或更新版本。用 flutter_patcher 1.0.0 构建的宿主用 flutter_patcher 1.0.0+1 打补丁，见[从 1.0 升级](upgrading-zh.md)。

**步骤**：

1. 把补丁文件放在服务端：`publish` 写在存储根目录下的 `<fileName>` 文件，或 `patch` 输出中 `file` 所指的文件。撤回文件的保存和下发方式相同，见[补丁下发回滚](production-playbook-zh.md#补丁下发回滚)。
2. 让 App 在请求中带上 `FlutterPatcher.patchTarget` 的字段，服务端返回要安装的文件，或不返回任何内容：

   | 字段 | 在服务端的用途 |
   |---|---|
   | `fileName` | 设备是哪个宿主构建；也是它的文件名 |
   | `fingerprint` | 同一个文件名对应多个构建时，用来区分它们 |
   | `acceptedSeq` | 设备已接受的最大序号；只有序号大于它的文件才会被安装 |
   | `versionCode`、`flavor`、`channel`、`abi`、`strategy`、`signed` | 用于选择文件的其他信息，例如灰度发布 |

3. 让 App 安装服务端返回的文件：

   ```dart
   import 'dart:io';

   import 'package:flutter/foundation.dart';
   import 'package:flutter_patcher/flutter_patcher.dart';

   /// 向自己的服务端请求本宿主的补丁文件并安装。
   Future<void> updateFromMyServer() async {
     final target = await FlutterPatcher.patchTarget; // 获取本宿主构建的标识
     final uri = Uri.https('api.example.com', '/patches', {
       'file': target.fileName,
       'fingerprint': target.fingerprint,
       'after': '${target.acceptedSeq}',
     });
     final client = HttpClient();
     try {
       final response = await (await client.getUrl(uri)).close();
       if (response.statusCode == HttpStatus.noContent) return; // 没有更新的文件
       if (response.statusCode != HttpStatus.ok) {
         throw HttpException('HTTP ${response.statusCode}', uri: uri);
       }
       final bytes = await consolidateHttpClientResponseBytes(response);
       // 校验并安装文件，下次冷启动生效
       final result = await FlutterPatcher.applyPatchBytes(bytes);
       if (!result.ok) {
         debugPrint('patch rejected: ${result.error?.name} ${result.message}');
       }
     } finally {
       client.close();
     }
   }
   ```

4. 可选：为了不下载设备会拒绝的文件，让 App 读取文件的前 146 字节并传给 `FlutterPatcher.inspectPatch`。只有属于本宿主、且序号大于 `acceptedSeq` 的补丁或撤回文件，`fresh` 才为 `true`。

**验证**：`applyPatchBytes` 返回 `ok: true`，`FlutterPatcher.currentVersion` 是该文件的 `seq`，下次冷启动后 `lastBootDiagnostic.status` 为 `patched`。

- 对签名宿主，服务端和传输通道无需可信，因为设备只安装由宿主的补丁密钥签名的文件。对不签名宿主，能改动 App 所收文件的一方就能在 App 中执行代码，所以请求必须通过 HTTPS 发往你信任的服务端。是否签名在构建宿主时确定，见[开启签名](production-playbook-zh.md#3-开启签名)。
