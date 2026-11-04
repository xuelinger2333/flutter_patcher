<!-- ========================================== -->
<!-- doc/advanced-zh.md (简体中文)              -->
<!-- ========================================== -->

# 进阶操作

[English](advanced.md) | **简体中文**

本文介绍日常发布之外偶尔需要的操作。日常的配置和发布流程见[生产部署](production-playbook-zh.md)。

## 轮换发布密钥

`publisher` 私钥泄露或丢失时，可以用 `root` 私钥签发一份新的信任文件，替换设备信任的发布公钥，无需重新发版。`patch` 或 `root` 私钥无法在线更换，需要发布新版本安装包。

设备通过 `updatePublicationTrust` 应用信任文件，因此应用中需要包含以下调用（例如由远程配置触发）：

```dart
final doc = await FlutterPatcher.fetchSignedManifest(
  'https://cdn.example.com/my-app-trust/trust.json',
);
await FlutterPatcher.updatePublicationTrust(doc);
```

### 步骤

1. 生成新的 publisher 密钥：`dart run flutter_patcher keys init --out new-publisher.json --role publisher`，输出中包含它的公钥。

2. 准备 `fields.json`，包含目标版本的 7 个标识字段，以及 `schema`、`revision` 和新的 `keys`：

   ```json
   {
     "application_id": "com.example.app",
     "channel": "production",
     "flavor": "default",
     "version_code": "1",
     "abi": "arm64-v8a",
     "fingerprint": "<基线 fingerprint>",
     "strategy": "bytecode",
     "schema": "1",
     "revision": "1",
     "keys": "release:<新的 publisher 公钥>"
   }
   ```

   - `keys` 使用 `release:<公钥>` 格式：项目中的 `publish` 固定使用名为 `release` 的密钥标识（`--production` 请求文件自行指定 `key_id`）。
   - 每次轮换时 `revision` 必须递增。

3. 用 `root` 私钥签名，并发布信任文件：

   ```bash
   dart run flutter_patcher trust sign --fields fields.json --out trust-1.json

   dart run flutter_patcher trust publish --wire trust-1.json \
     --store s3://my-bucket/my-app-trust
   ```

   `trust sign` 获取 root 私钥的方式与 `publish` 获取私钥相同（见[私钥从哪里来](cli-zh.md#私钥从哪里来)），例如用 `--key-file root-backup.json` 指定离线保存的备份。

   每个线上版本有各自的信任文件，请为每个版本使用单独的 `--store` 位置。位置中已有其他版本的信任文件时，`trust publish` 会报 `TRUST_SCOPE_CONFLICT`。

4. 用 `dart run flutter_patcher keys import new-publisher.json --rotate` 换上新密钥并提交 `flutter_patcher.yaml`，然后重新生成并发布一次最新补丁。负责发布的机器和 CI 也需要换上新密钥（`keys export`）。

### 生效方式

设备应用新的信任文件后，旧 `publisher` 私钥签名的清单不再被接受，通过这类清单安装的补丁会被立即移除。因此替换密钥后请立即用新密钥发布一次补丁，使设备保持在最新的补丁版本。

## 清理历史补丁

发布存储中的历史补丁不会自动删除。需要释放空间时，准备清理请求文件 `cleanup.json`：

```json
{
  "kind": "cleanup",
  "application_id": "com.example.app",
  "store": "s3://my-bucket/my-app",
  "operation": "<32 位随机小写十六进制字符串>",
  "cutoff": 1790000000
}
```

1. 生成清理计划，不删除任何内容：

   ```bash
   dart run flutter_patcher publish --production --request cleanup.json --receipt cleanup-plan.json
   ```

2. 核对 `cleanup-plan.json` 后，在 `cleanup.json` 中加入 `"approved_plan": "<cleanup-plan.json 的绝对路径>"`，然后执行：

   ```bash
   dart run flutter_patcher publish --production --request cleanup.json --yes
   ```

以下内容不会被清理：各版本当前生效的补丁、创建时间不早于 `cutoff` 的补丁、以 `"pin": true` 发布的记录，以及基线存储中的所有基线。
