<!-- ========================================== -->
<!-- doc/advanced-zh.md (简体中文)               -->
<!-- ========================================== -->

# 进阶操作

[English](advanced.md) | **简体中文**

偶尔才需要的操作。日常的配置和发布见[生产部署](production-playbook-zh.md)。

## 用 KMS 或签名服务签名

**目标**：用一把始终不离开 KMS、Vault、HSM 或密码管理器的密钥为补丁文件签名。

**前置条件**：该服务持有一把 Ed25519 密钥，并能做纯 Ed25519 签名（RFC 8032，不是 Ed25519ph）。

**操作**：

1. 把它的公钥（原始 32 字节的 base64）和签名命令写进 `flutter_patcher.yaml`：

   ```yaml
   trust:
     patch: <base64 的 Ed25519 公钥>
   signing:
     command: my-signer --key fp-patch
   ```

   命令从 stdin 读取待签名的字节，在 stdout 输出 base64 编码的 64 字节签名，并在 60 秒内以退出码 0 结束。它通过 `/bin/sh -c` 运行（Windows 上写成批处理文件、经 `cmd.exe` 运行），环境中设置了 `FLUTTER_PATCHER_SIGN_ROLE=patch` 和 `FLUTTER_PATCHER_SIGN_PUBLIC_KEY=<trust.patch>`，并去掉了 `FLUTTER_PATCHER_KEYS`。

2. 重新构建宿主：此后构建的宿主只接受这把密钥签名的文件。

**验证**：`dart run flutter_patcher keys status` 显示 `"private_key":"signing.command"`，`publish` 输出 `"signed":true`。

`--key-file` 和 `FLUTTER_PATCHER_KEYS` 的优先级高于 `signing.command`；需要使用签名命令的机器上不要设置它们。每个签名在使用前都会用 `trust.patch` 验证：命令失败、超时或用了别的密钥时，`publish` 以 `SIGNER_COMMAND_FAILED` 停止。

## CI 中的密钥

**目标**：让 CI 任务不依赖密钥库也能签名。

**操作**：

1. 在持有密钥的机器上，把密钥包输出为一行，保存为 CI 的 secret：

   ```bash
   dart run flutter_patcher keys export --base64
   ```

2. 把这个 secret 作为环境变量 `FLUTTER_PATCHER_KEYS` 提供给任务，并带 `--yes` 发布。没有终端时，不带 `--yes` 的 `publish` 只做预览：

   ```bash
   dart run flutter_patcher publish --yes
   ```

**验证**：任务中的 `keys status` 显示 `"private_key":"FLUTTER_PATCHER_KEYS"`。

密钥包里是别的密钥时报 `KEYS_MISMATCH`，不会跳过它去找下一个来源。1.0 的密钥包同样可用：只使用其中的补丁密钥。如果想把密钥包导入密钥库，运行 `keys import -`，从 stdin 传入。

## 自定义宿主策略

**目标**：用你自己写的策略文件构建宿主，而不是由 `build` 从项目推导。

**操作**：编写策略文件，它是一个所有值都为字符串的 JSON 对象，字段恰好为：

```json
{
  "schema": "2",
  "strategy": "bytecode",
  "abi": "arm64-v8a",
  "application_id": "com.example.app",
  "version_code": "7",
  "flavor": "default",
  "channel": "production",
  "fptc_key": "<base64 的 Ed25519 公钥；不签名的宿主写 ->"
}
```

然后用它构建：

```bash
dart run flutter_patcher build android --host-policy policy.json
```

- `abi` 为 `arm64-v8a`（`build android`）或 `ios-arm64`（`build ios`，此时 `strategy` 必须是 `bytecode`）。
- 策略必须与构建一致：`flavor` 与 `--flavor`（默认 `default`）一致，给了 `--version-code` 时 `version_code` 与它一致，否则 `build` 报 `BUILD_CONFIG_INVALID`。`application_id` 和 `version_code` 必须是 App 的包名（iOS 的 bundle id）和构建号：设备会与已安装的 App 核对。
- 宿主是否签名由文件中的 `fptc_key` 决定，不使用 `flutter_patcher.yaml` 中的 `trust.patch`。
- 也接受 flutter_patcher 1.0 的策略文件（`"schema": "1"`）：保留其中的 `fptc_key`，丢弃 `root_key` 和 `keys`。

其他内容报 `BUILD_CONFIG_INVALID`。

## 发布到 S3

**目标**：让 `publish` 直接把补丁文件写入 S3 存储桶，或兼容 S3 API 的服务。

**前置条件**：已安装 AWS CLI（`aws`），并按它通常的配置方式拥有该存储桶的凭据；存储地址中不能包含凭据。服务支持条件写入（`PutObject` 的 `If-None-Match` 和 `If-Match`）。

**操作**：在 `flutter_patcher.yaml` 中把存储设为存储桶中的一个专用前缀：

```yaml
store: s3://my-bucket/my-app
url: https://cdn.example.com/my-app
```

使用 AWS 以外的 S3 兼容服务时，把 `FLUTTER_PATCHER_S3_ENDPOINT` 设为它的 endpoint 地址。

**验证**：`publish` 之后，存储桶中有 `my-app/<fileName>`，例如 `my-app/7-arm64-v8a.fptc`，并且 `https://cdn.example.com/my-app/<fileName>` 能下载到它。

- 必须使用前缀（不能是存储桶根目录），前缀的每一段只能包含字母、数字、`_` 和 `-`。
- `publish` 先读取那里的文件，只在它此后未被改动时才写入：两次发布同时进行时，其中一次报 `PUBLISH_CONFLICT`，重新发布即可。

## 从自家接口下发补丁文件

**目标**：设备从你自己的后端获取补丁文件，由后端决定给谁哪个文件，而不是从固定的 URL 下载。

**操作**：

1. 在服务端保存 `publish` 写出的文件（存储根目录下的 `<fileName>`），或从 `patch` 的输出目录中取。
2. 在 App 中向服务端请求本宿主的文件，交给插件：

   ```dart
   final target = await FlutterPatcher.patchTarget;
   // 你自己的请求：把服务端挑选文件所需的信息发过去。
   final bytes = await myApi.fetchPatch(
     file: target.fileName,           // 例如 7-arm64-v8a.fptc
     acceptedSeq: target.acceptedSeq, // 本机已接受的最大序号；从未接受过时为 0
   );
   if (bytes != null) {
     final result = await FlutterPatcher.applyPatchBytes(bytes);
     if (!result.ok) report(result.error, result.message); // 换成你自己的上报方式
   }
   ```

   已经在磁盘上的文件（例如随 App 内嵌的文件，或你自己的代码下载的文件）交给 `applyPatchFile(path)`；插件不会删除这个文件。

3. 想避免下载设备不会接受的文件时，先读取文件的前 146 字节，交给 `FlutterPatcher.inspectPatch(header)`：只有本宿主更新的补丁或撤回，`fresh` 才为 true。

**验证**：`applyPatchBytes` 返回 `ok: true`，`FlutterPatcher.currentVersion` 是该文件的序号，下次冷启动后 `lastBootDiagnostic` 的 `status` 为 `patched`。

- 无论文件从哪里来，原生代码都会校验整个文件；`inspectPatch` 不能代替这一步。
- 签名宿主上，你的服务端和传输链路都不需要可信。不签名宿主上，谁能改动 App 收到的文件，谁就能在 App 中执行代码，因此请求必须通过 HTTPS 发往你信任的服务端。
- 撤回文件同样通过 `applyPatchBytes` 应用。
- `PatchTarget` 的其他字段：`versionCode`、`flavor`、`channel`、`abi`、`strategy`、`fingerprint`、`signed`。完整 API 见 [API 参考](api-reference-zh.md)。
