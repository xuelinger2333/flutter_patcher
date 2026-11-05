<!-- ========================================== -->
<!-- doc/production-playbook-zh.md (简体中文)    -->
<!-- ========================================== -->

# 生产部署

[English](production-playbook.md) | **简体中文**

本文提供从本地跑通（[快速上手](getting-started-zh.md)）到生产上线的最短路径。核心命令与快速上手一致：`publish` 仍将产物写入本地项目，你只需将其上传至自己的 HTTPS 服务供设备下载。

标有 **按需替换** 的步骤可根据实际环境调整，详见[按需替换](#按需替换)。完整参数见 [CLI 参考](cli-zh.md)。

## 前置条件

- 已按快速上手在本地跑通流程（含 `keys init`）。
- 准备一个可写入的 HTTPS 地址（对象存储 + CDN、自建服务器或静态托管均可）。要求：直接返回文件、不做重定向，且不对 `manifests/` 做长缓存。详见 [CLI 参考：存储要求](cli-zh.md#存储要求)。

## 第 1 步：备份私钥

**目标**：留一份私钥备份。补丁必须用私钥签名，设备才会安装。

`keys init` 生成的私钥保存在本机的 `~/.flutter_patcher/keys/<项目 ID>/keys.json`（Windows 下 `~` 即用户目录），不在项目目录里，也不会随 git 提交。这个文件丢了，已上线的版本就无法再发补丁。

**操作**：导出一份备份，存到本机以外的地方：

```bash
dart run flutter_patcher keys export --out fp-keys.json
```

> **按需替换**：跨机器、CI 自动发布，或接入 KMS 签名服务，见[在别的机器或 CI 上发布](#在别的机器或-ci-上发布)。

**验证**：命令输出 `"status":"keys_exported"`，以及备份文件的路径 `file`。
## 第 2 步：配置线上更新地址

**目标**：将 Release 包的检查地址从本地 `serve` 切换为线上 HTTPS 地址。

**操作**：

1. 在 `flutter_patcher.yaml` 中填写第 5 步的文件上传地址：

   ```yaml
   url: https://cdn.example.com/my-app
   ```

   `build` 会把它写进 App，快速上手中的 `checkUpdate()` 无需改动。`publish` 也会在编号前先读取这个地址上的线上状态。

2. 确认 `android/app/src/main/AndroidManifest.xml` 包含网络权限（无此权限 Release 包无法联网）。

> **按需替换**：先向小比例用户放量，见[灰度发布](#灰度发布)。

## 第 3 步：发布商店基线包

**目标**：构建支持热修的基线版本并上架应用商店。

**操作**：

1. 构建发版包：

   ```bash
   dart run flutter_patcher build android    # build ios 需在 Apple Silicon Mac 上运行
   ```

2. 将生成的 `app-release.apk`（或 `app-release.ipa`）提交至应用商店。

**验证**：

- `build` 输出 `"status":"build_archived"`，并且不再出现 `WARNING: URL_LOCAL`。
- 仍会出现 `WARNING: BASELINE_STORE_LOCAL` 提示：表示基线保存在项目的 `.flutter_patcher/` 文件夹里，见[不能丢的文件夹](#不能丢的文件夹)。

## 第 4 步：生成并发布补丁

**目标**：修复线上问题，生成签名补丁并分配序号。

**操作**：

1. 修复问题，不要修改 `pubspec.yaml` 中的 `version`。
2. 生成补丁：

   ```bash
   dart run flutter_patcher patch android    # patch ios 可在任一支持的电脑上运行
   ```

3. 写入发布记录（默认展示预览并需手动确认；CI 等无人值守环境请加 `--yes`）：

   ```bash
   dart run flutter_patcher publish
   ```

**验证**：

- `patch` 输出 `"status":"patch_created"`。
- `publish` 输出 `"status":"published"`、递增的补丁序号 `patch_seq`（同版本依次为 1、2、3…）以及清单路径 `manifest`（如 `manifests/<hash>.json`）。

编号前，`publish` 会先读取 `url` 上该版本的清单，保证新序号不会低于设备可能已有的序号。读取失败时，它以 `PUBLISH_URL_UNREACHABLE` 停止，不发布任何内容。

> **按需替换**：修复非最新的历史线上版本，见[给更早的版本打补丁](#给更早的版本打补丁)。

## 第 5 步：上传产物

**目标**：将补丁同步至线上地址，供设备下载。

`publish` 会将产物写入 `.flutter_patcher/updates/`。将其中两个文件夹按以下严格顺序上传至第 2 步的线上地址（保持目录名不变）：

1. 先传 `objects/`
2. 后传 `manifests/`

注意：

- 每次执行 `publish`（含撤回）后均需重新上传。
- 切勿上传 `catalog.json` 和 `.publish.lock`（仅供 CLI 内部维护状态）。
- 为什么顺序不能反：若先传 `manifests/`，设备拉取新清单后会立即请求尚未上传的 `objects/` 文件，导致本次更新失败，要等下次检查才能成功。

> **按需替换**：配置 S3/R2 直传以省去手动上传，见[让 publish 直接写入存储桶](#让-publish-直接写入存储桶)。

**验证**：访问 `<线上地址>/<publish 输出的 manifest>` 返回 HTTP `200`。已安装对应基线包的设备在下次检查时下载补丁，冷启动后生效。

## 补丁回滚与撤回

**目标**：停用线上问题补丁。任选以下一种方式执行，随后按第 5 步重新上传。

**方式一：彻底撤回（回退至安装包初始状态）**

```bash
dart run flutter_patcher publish --withdraw
```

默认撤回最近一次 `patch` 对应版本的全部补丁；可用 `--patch <目录>` 指定其他版本的补丁目录。

**方式二：回退至历史正常补丁**

重新发布指定的历史正常补丁，使其获得新序号并作为常规更新下发：

```bash
dart run flutter_patcher publish --patch .dart_tool/flutter_patcher/patches/<目录>
```

历史补丁默认保留在 `.dart_tool/flutter_patcher/patches/`；若已清理，检出当时源码重新运行 `patch` 即可。切勿重新发布问题补丁，否则设备会再次安装。

**生效机制**：设备仅保留一个补丁，且只接受序号更大的补丁（因此回退旧补丁必须重新 `publish` 递增序号）。撤回或重发后，App 在 `checkUpdate` 发现 `hasUpdate == true` 并调用 `applyPatch` 后下载，下次冷启动时生效。

**验证**：

- 方式一：`publish` 输出 `"action":"withdraw"`；设备冷启动生效后，`FlutterPatcher.currentVersion` 为 `null`，`lastBootDiagnostic` 为 `noPatch`。
- 方式二：`publish` 输出的 `patch_seq` 大于问题补丁序号；设备冷启动生效后，`currentVersion` 更新为该新序号。

## 不能丢的文件夹

项目里的 `.flutter_patcher/baselines/` 保存着各线上版本的构建基线，请纳入备份。丢失后，丢失前构建的线上版本将无法再生成补丁。它和第 1 步备份的私钥，就是上线后需要保管的全部东西。

`.flutter_patcher/updates/` 无需备份：设备已有的内容就在 `url` 上，`publish` 会从那里读取。

## 按需替换

### 让 publish 直接写入存储桶

配置 AWS S3 或 Cloudflare R2 等 S3 兼容服务后，`publish` 可直接写入远端存储桶。既省去手动上传，又能将发布记录集中在桶内，支持多机与 CI 协同发布。

**操作**：

1. 在发布机上安装 AWS CLI，配置具备存储桶写权限的凭证。若使用 S3 兼容服务，需设置环境变量 `FLUTTER_PATCHER_S3_ENDPOINT` 为对应服务地址。权限要求见 [CLI 参考：存储要求](cli-zh.md#存储要求)。
2. 在 `flutter_patcher.yaml` 中配置存储路径：

   ```yaml
   store: s3://my-bucket/my-app
   baseline_store: s3://my-bucket/baselines
   ```

3. 权限隔离：仅将 `my-app` 前缀设为公开读（第 2 步把它的 HTTPS 地址填为 `url`），`baselines` 保持私有。

`store` 供 CLI 凭你的凭证写入，HTTPS 地址供设备免密读取。

**验证**：运行 `dart run flutter_patcher doctor --baseline-store s3://my-bucket/baselines`，确认 `baseline_store` 检查通过，且 `build` 不再提示 `WARNING: BASELINE_STORE_LOCAL`。

### 通过自定义接口下发

若设备必须通过自有后端接口鉴权下载，可由 App 自行请求清单与补丁并传入 [`applySignedManifest`](api-reference-zh.md#自行分发清单)。CLI 发布流程不变，仅将文件托管方从公开 CDN 替换为你的后端服务。

### 在别的机器或 CI 上发布

仅签名操作（`publish`、`serve`、`trust sign`）需要私钥，生成补丁（`patch`）无需私钥：

| 角色 | 所需资产 |
|---|---|
| 构建补丁的机器 | 源码 + 基线（无需私钥） |
| 执行发布的机器 | publisher 与 patch 私钥 + 基线 + 能访问 `url` |
| 密钥轮换操作 | root 私钥（日常必须离线保存） |

多机协同发布时，请务必[让 publish 直接写入存储桶](#让-publish-直接写入存储桶)，这样每次发布都能立即看到上一次的结果，不必等上传。

所有发布端共用同一套密钥，无需重新生成。按场景注入私钥：

| 发布环境 | 私钥注入方式 |
|---|---|
| 另一台本地电脑 | 原电脑运行 `keys export --out <文件>`，新电脑运行 `keys import <文件>` |
| CI 环境（如 GitHub Actions） | 将 `keys export --base64 --without-root` 输出的单行文本存入 CI Secret，作为环境变量 `FLUTTER_PATCHER_KEYS` 注入，执行 `publish --yes`（不含日常无需使用的 root 私钥） |
| KMS 等外部签名服务（私钥不出域） | 配置 `signing.command` 委托外部服务完成签名，私钥全程不落地。详见 [CLI 参考：私钥从哪里来](cli-zh.md#私钥从哪里来) |

**验证**：在发布机上运行 `dart run flutter_patcher keys status`，确认 publisher 和 patch 私钥来源均不为 `none`。

### 灰度发布

**目标**：按比例逐步放量，验证稳定后再全量推开。

补丁一旦发布，同版本所有设备均可拉取。灰度控制由客户端结合远程配置（Remote Config）在调用检查前拦截：

```dart
if (userBucket(userId) < rolloutPercent) {
  final check = await FlutterPatcher.checkUpdate();
  if (check.hasUpdate) {
    await FlutterPatcher.applyPatch(check.patch!);
  }
}
```

其中 `userBucket` 将用户固定哈希至 0–99 区间，`rolloutPercent` 由远程配置动态下发，两者都由你实现。

**操作**：按梯度上调 `rolloutPercent`（如 1% → 5% → 20% → 100%）。

**验证**：每次扩量前，监控应用崩溃率及[启动诊断](crash-protection-zh.md#启动诊断)中 `isHealthy == false` 的异常比例。

### 给更早的版本打补丁

切回该版本的源码，修复后携带 `--version-code` 生成补丁：

```bash
dart run flutter_patcher patch android --version-code <构建号>
```

随后按第 4、5 步正常发布上传。不同版本的基线与补丁序号完全独立。

## 内置安全机制

- **签名与完整性校验**：设备强制校验签名、哈希与目标版本，CDN 或传输途中被篡改的文件会被直接拒绝。
- **防重放攻击**：设备仅安装序号大于当前已装补丁的版本，已撤回的序号无法重放。
- **启动崩溃保护**：引发启动崩溃的补丁会被自动熔断停用，下次冷启动自动回退至安装包自带的版本。详见[崩溃保护](crash-protection-zh.md)。
- **并发防覆盖**：多机同时向同一存储桶发布时，以条件写入保证不会互相覆盖。
- **中断恢复**：`publish` 意外中断后，在同一项目中重新运行即可完成。

## 进阶操作

- [轮换发布密钥](advanced-zh.md#轮换发布密钥)：publisher 私钥泄露或丢失时，无需重发商店包即可在线轮换。
- [清理历史补丁](advanced-zh.md#清理历史补丁)：清理发布存储中的过期补丁以释放空间。
- [自行分发清单](api-reference-zh.md#自行分发清单)：通过自有后端接口下发补丁与清单。