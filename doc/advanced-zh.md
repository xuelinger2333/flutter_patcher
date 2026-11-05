<!-- ========================================== -->
<!-- doc/advanced-zh.md (简体中文)               -->
<!-- ========================================== -->

# 进阶操作

[English](advanced.md) | **简体中文**

偶尔才需要的操作。日常的配置和发布见[生产部署](production-playbook-zh.md)。

## 轮换发布密钥

**目标**：`publisher` 私钥丢失或泄露时，无需发布商店版本即可更换。`patch` 和 `root` 私钥不能这样更换，更换它们需要发布商店版本。

**前置条件**：

- App 能应用信任文件。在 App 中加入以下调用，例如由远程配置触发：

  ```dart
  final doc = await FlutterPatcher.fetchSignedManifest(
    'https://cdn.example.com/my-app-trust/trust.json',
  );
  await FlutterPatcher.updatePublicationTrust(doc);
  ```

- 手里有 `root` 私钥，例如用 `keys export` 离线保存的备份。

**操作**：

1. 生成新的 publisher 密钥，输出中有它的公钥：

   ```bash
   dart run flutter_patcher keys init --out new-publisher.json --role publisher
   ```

2. 为线上版本准备 `fields.json`：它的 7 个标识字段，加上 `schema`、`revision` 和新的 `keys`。`fingerprint` 取自该版本 `patch.json` 中的 `scope.fingerprint`，或 `publish` 输出中的 `fingerprint`：

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

   - `keys` 的格式是 `release:<公钥>`：项目中的 `publish` 固定使用名为 `release` 的密钥标识（`--production` 请求文件自行指定 `key_id`）。
   - 每次轮换时 `revision` 必须递增。

3. 用 `root` 私钥签名并发布。`trust sign` 获取 root 私钥的方式与 `publish` 相同（见[私钥从哪里来](cli-zh.md#私钥从哪里来)），例如 `--key-file root-backup.json`：

   ```bash
   dart run flutter_patcher trust sign --fields fields.json --out trust-1.json
   dart run flutter_patcher trust publish --wire trust-1.json --store s3://my-bucket/my-app-trust
   ```

   每个线上版本有各自的信任文件，请为每个版本使用单独的 `--store` 位置。位置中已有其他版本的信任文件时报 `TRUST_SCOPE_CONFLICT`。

4. 换上新密钥，并提交 `flutter_patcher.yaml`。负责发布的机器和 CI 也需要换上新密钥（`keys export`）：

   ```bash
   dart run flutter_patcher keys import new-publisher.json --rotate
   ```

5. 重新生成并发布一次最新的补丁：先 `patch`，再 `publish`。

**验证**：

- `trust sign` 和 `trust publish` 执行成功，信任文件出现在 App 获取的地址上。
- `keys status` 显示新的 publisher 公钥。
- 第 5 步的 `publish` 输出 `"status":"published"`。

设备应用新的信任文件后，不再接受旧 `publisher` 私钥签名的清单，通过这类清单安装的补丁会被立即移除。第 5 步让设备保持在最新的补丁上。

## 清理历史补丁

**目标**：释放发布存储的空间。历史补丁不会自动删除。

**操作**：

1. 准备清理请求文件 `cleanup.json`。`cutoff` 是以秒为单位的 Unix 时间，只有在它之前创建的补丁才可能被删除：

   ```json
   {
     "kind": "cleanup",
     "application_id": "com.example.app",
     "store": "s3://my-bucket/my-app",
     "operation": "<32 位随机小写十六进制字符串>",
     "cutoff": 1790000000
   }
   ```

2. 生成清理计划，此时不删除任何内容：

   ```bash
   dart run flutter_patcher publish --production --request cleanup.json --receipt cleanup-plan.json
   ```

3. 核对 `cleanup-plan.json`，在 `cleanup.json` 中加入 `"approved_plan": "<cleanup-plan.json 的绝对路径>"`，然后执行：

   ```bash
   dart run flutter_patcher publish --production --request cleanup.json --yes
   ```

**验证**：第 2 步生成的 `cleanup-plan.json` 列出将被删除的内容；第 3 步执行成功，这些对象从存储中消失。

以下内容不会被清理：各版本当前的补丁、创建时间不早于 `cutoff` 的补丁、以 `"pin": true` 发布的记录，以及基线存储中的任何内容。

## 自行分发清单

设备必须通过你自己的接口、而不是直接从发布存储下载时，可以自己获取清单和补丁，交给插件校验和安装。见 [API 参考：自行分发清单](api-reference-zh.md#自行分发清单)。
