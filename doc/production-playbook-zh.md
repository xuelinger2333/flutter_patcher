<!-- ========================================== -->
<!-- doc/production-playbook-zh.md (简体中文)    -->
<!-- ========================================== -->

# 生产部署指南

[English](production-playbook.md) | **简体中文**

本文档介绍如何将本地验证完毕的补丁流程（参考[快速上手](getting-started-zh.md)）迁移至生产环境。生产核心命令与本地完全一致：执行 `publish` 仍然将分发产物生成至本地目录，之后只需同步至线上的 HTTPS 静态文件服务即可。

文档中带有 **按需调整** 标识的步骤，可根据实际基建情况选用（详见[进阶与按需方案](#进阶与按需方案)）。完整参数说明请参阅 [CLI 参考](cli-zh.md)。

## 前置准备

- 已按快速上手指南完成本地流程联调（包括执行过 `keys init`）。
- 准备一个支持直接读取的 HTTPS 存储端（对象存储 + CDN、自建 Nginx 或静态托管均可）。硬性要求：直接返回文件内容、不做 URL 重定向，且不得对 `manifests/` 目录开启长缓存。详见 [CLI 参考：存储要求](cli-zh.md#存储要求)。

## 1. 备份签名私钥

补丁必须经过私钥签名，设备才会验证并加载。

`keys init` 生成的私钥保存在本机的 `~/.flutter_patcher/keys/<项目 ID>/keys.json`（Windows 下 `~` 即当前用户目录）。该文件不在项目仓库内，不会随 Git 提交。一旦私钥遗失，已上线的版本将无法再发布补丁。

执行以下命令导出私钥，并保存到本机以外的地方（如公司密钥库或离线介质）：

```bash
dart run flutter_patcher keys export --out fp-keys.json
```

> **按需调整**：CI/CD 自动化构建、跨机器协作或对接 KMS 签名服务，参见[多机协同与 CI 发布](#多机协同与-ci-发布)。

**校验项**：终端返回 `"status":"keys_exported"` 以及备份文件路径 `file`，即代表导出成功。

## 2. 配置生产分发地址

将客户端检查更新的地址从本地 `serve` 切换为正式 HTTPS 地址。

1. 编辑 `flutter_patcher.yaml`，填入对外提供静态文件访问的根地址（即第 5 步的上传位置）：

   ```yaml
   url: https://cdn.example.com/my-app
   ```

   之后执行 `build` 会把该地址写入 App，客户端调用 `checkUpdate()` 无需改动代码；执行 `publish` 时，CLI 也会先读取该地址上的线上清单，确定当前的补丁序号。

2. 检查 `android/app/src/main/AndroidManifest.xml`，确保已声明网络权限（缺少时 Release 包无法联网检查更新）：

   ```xml
   <uses-permission android:name="android.permission.INTERNET" />
   ```

> **按需调整**：需要按比例逐步放量？参见[灰度发布策略](#灰度发布策略)。

## 3. 构建并提交商店基线包

构建支持热更新的安装包，并上架应用商店。

1. 打包生产构建：

   ```bash
   dart run flutter_patcher build android    # build ios 必须在 Apple Silicon Mac 上执行
   ```

2. 将生成的 `app-release.apk`（或 `app-release.ipa`）按正常流程提交至应用市场。

**校验项**：

- 输出 `"status":"build_archived"`，本地调试时出现的 `WARNING: URL_LOCAL` 不再出现。
- 仍会提示 `WARNING: BASELINE_STORE_LOCAL`：表示构建基线保存在项目的 `.flutter_patcher/` 目录下，请阅读[核心不可丢失数据](#核心不可丢失数据)。

## 4. 生成与发布补丁

修复线上 Bug，生成签名补丁并分配递增序号。

1. 修复业务代码。注意：不要修改 `pubspec.yaml` 中的 `version` 字段。
2. 生成补丁：

   ```bash
   dart run flutter_patcher patch android    # patch ios 可在任一支持的主机上运行，不需要 Mac
   ```

3. 写入发布记录（默认先展示发布摘要，输入 `y` 确认；在 CI 等非交互环境中运行请加 `--yes`）：

   ```bash
   dart run flutter_patcher publish
   ```

**校验项**：

- `patch` 返回 `"status":"patch_created"`。
- `publish` 返回 `"status":"published"`，并输出递增的补丁序号 `patch_seq`（同一版本依次为 1、2、3…）以及清单路径 `manifest`（如 `manifests/<hash>.json`）。

**说明**：分配序号前，`publish` 会先读取 `url` 上该版本的线上清单，保证新序号不会低于设备可能已有的序号。读取失败时，命令以 `PUBLISH_URL_UNREACHABLE` 终止，不发布任何内容。

> **按需调整**：给非最新的存量版本发补丁，参见[为存量旧版本打补丁](#为存量旧版本打补丁)。

## 5. 同步产物至静态存储

将生成的文件上传至线上地址，供设备下载。

`publish` 执行后，会在 `.flutter_patcher/updates/` 下生成待发布产物。请将其中两个目录按以下次序上传至第 2 步的线上根目录（保持目录名不变）：

1. 先传 `objects/`
2. 后传 `manifests/`

**关键约束**：

- **不要颠倒上传顺序**：若先上传 `manifests/`，设备拿到新清单后会立即下载它指向的补丁文件，此时 `objects/` 尚未上传，下载返回 404，这次更新失败，要等 App 下次调用 `checkUpdate` 才会重试。
- 每次运行 `publish`（包括下文的回滚与撤回）后，都需要把变动重新同步上线。
- 不要上传 `catalog.json` 和 `.publish.lock`（CLI 本地使用的状态文件）。

> **按需调整**：配置 S3/R2 直传，省去手动上传，参见[让 publish 直接写入远端存储桶](#让-publish-直接写入远端存储桶)。

**校验项**：直接请求 `<线上地址>/<publish 输出的 manifest 路径>`，确认返回 HTTP `200` 且内容为完整的 JSON。已安装该基线版本的 App 在下次检查更新并下载后，冷启动即生效。

## 补丁回滚与撤回

线上补丁出问题时的止损操作。按实际需要任选其一，执行完毕后同样需要按第 5 步重新同步产物。

**方案 A：彻底撤回（回到安装包自带的版本）**

```bash
dart run flutter_patcher publish --withdraw
```

默认撤回最近一次 `patch` 所对应版本的**全部**已发布补丁。如需指定其他版本，加 `--patch <该版本的补丁目录>`。

**方案 B：回退至某次历史正常补丁**

把旧的正常补丁重新发布，它会获得一个更大的新序号，作为常规更新推给客户端：

```bash
dart run flutter_patcher publish --patch .dart_tool/flutter_patcher/patches/<目标目录>
```

历史补丁默认保留在 `.dart_tool/flutter_patcher/patches/`。若已被清理，检出当时的代码重新执行一次 `patch` 即可。不要重新发布出问题的补丁，否则设备会再次安装它。

**客户端生效原理**：设备只保留一个补丁，并且只接受序号大于它已接受过的最大序号的补丁。撤回和重发本质上都是发布一份新的清单：撤回清单让设备删除补丁，重发清单带着新序号。客户端在 `checkUpdate` 中得到 `hasUpdate == true` 并完成 `applyPatch` 后，下次冷启动生效。

**校验项**：

- 方案 A：CLI 返回 `"action":"withdraw"`。设备冷启动后，`FlutterPatcher.currentVersion` 为 `null`，`lastBootDiagnostic` 为 `noPatch`。
- 方案 B：CLI 输出的 `patch_seq` 大于问题补丁的序号。设备冷启动后，`currentVersion` 为这个新序号，内容回到稳定代码。

## 核心不可丢失数据

项目根目录下的 `.flutter_patcher/baselines/` 保存着每个线上版本的构建基线（编译产物、源码哈希、依赖、资源与公钥）。

- **必须归档备份**：基线丢失后，对应的线上版本将再也无法生成补丁。
- **与私钥并列**：上线后需要保管的只有两样，导出的私钥和 `baselines` 目录。

注：`.flutter_patcher/updates/` 丢失无需担心。设备看到的清单就在 `url` 上，`publish` 编号前会从那里读取当前状态。

## 进阶与按需方案

### 让 publish 直接写入远端存储桶

支持 AWS S3、Cloudflare R2 等兼容 S3 协议的对象存储。配置后 `publish` 直接上传对象并维护发布记录，省去手动上传，发布记录也集中在桶内，便于多机与 CI 协同。

1. 在发布机上安装 AWS CLI，并配置具备写权限的凭证（AK/SK）。权限要求见 [CLI 参考：存储要求](cli-zh.md#存储要求)。第三方对象存储通过环境变量指定服务地址：

   ```bash
   export FLUTTER_PATCHER_S3_ENDPOINT="https://<account_id>.r2.cloudflarestorage.com"
   ```

2. 在 `flutter_patcher.yaml` 中配置目标路径：

   ```yaml
   store: s3://my-bucket/my-app
   baseline_store: s3://my-bucket/baselines
   ```

3. 权限管控：将 `my-app` 前缀设为公开只读（它的 HTTPS 地址就是第 2 步的 `url`），`baselines` 前缀必须保持私有。

**校验项**：运行以下命令，确认 `baseline_store` 检查通过；之后执行 `build` 不再提示 `WARNING: BASELINE_STORE_LOCAL`。

```bash
dart run flutter_patcher doctor --baseline-store s3://my-bucket/baselines
```

### 多机协同与 CI 发布

生成补丁与签名发布相互独立，只有签名操作（`publish`、`serve`、`trust sign`）需要私钥：

| 角色 | 所需资产 |
|---|---|
| 补丁构建机（本地/编译机） | 源码 + 对应版本的基线（无需私钥） |
| 发布执行节点（发布机/CI） | publisher 与 patch 私钥 + 基线 + 能访问 `url` |
| 密钥轮换 | root 私钥（日常不需要，不要放进 CI，离线保管） |

多台机器发布同一个 App 时，请[让 publish 直接写入远端存储桶](#让-publish-直接写入远端存储桶)：每次发布都能立即看到上一次的结果，不会因为别人还没上传而分到重复的序号。

私钥分发方式：

- **迁移到另一台本地电脑**：源机器执行 `keys export --out <文件>`，目标机器执行 `keys import <文件>`。
- **注入 CI（如 GitHub Actions）**：执行 `keys export --base64 --without-root`，得到不含 root 私钥的单行文本（仍包含 publisher 与 patch 私钥，按机密处理），存入 CI Secret 并作为环境变量 `FLUTTER_PATCHER_KEYS` 注入，流水线中带 `--yes` 运行：

  ```bash
  dart run flutter_patcher publish --yes
  ```

- **KMS / 外部签名服务**：配置 `signing.command` 委托外部服务签名，私钥不离开签名服务。详见 [CLI 参考：私钥配置](cli-zh.md#私钥从哪里来)。

**校验项**：在发布机上运行 `dart run flutter_patcher keys status`，确认 publisher 和 patch 私钥的来源都不是 `none`。

### 灰度发布策略

补丁一旦上线，所有访问该清单的同版本设备都能拉取。若需按比例放量，可在客户端检查更新前加一道动态开关（如 Firebase Remote Config 或自建配置中心）：

```dart
// 灰度放量拦截
if (userBucket(userId) < rolloutPercent) {
  final check = await FlutterPatcher.checkUpdate();
  if (check.hasUpdate) {
    await FlutterPatcher.applyPatch(check.patch!);
  }
}
```

- `userBucket(userId)`：将用户唯一标识（如 UUID）哈希取模，映射至 0–99。
- `rolloutPercent`：由后台配置下发的百分比（如 `5` 代表 5%）。

两者都由你实现。逐步上调放量比例（例如 1% → 10% → 30% → 全量），期间观察崩溃率以及[启动诊断](crash-protection-zh.md#启动诊断)中 `isHealthy == false` 的比例。

### 为存量旧版本打补丁

线上有多个版本并存且需要修复时，切回对应版本的代码，指定该版本的构建号生成补丁：

```bash
dart run flutter_patcher patch android --version-code <构建号>
```

随后按第 4、5 步正常发布并同步。不同版本的基线与补丁序号相互独立，互不干扰。

## 底层保护机制

- **防篡改与完整性校验**：设备校验清单和补丁的签名、SHA-256 与目标版本，中间人篡改或 CDN 缓存损坏的文件会被直接拒绝。
- **防降级与防重放**：设备持久记录已接受过的最大补丁序号，只安装序号更大的补丁；已撤回的序号不能再次生效。
- **启动熔断保护**：补丁导致启动失败（首帧前崩溃或 ANR，或首帧后 `verifyAfter` 内出现未捕获的 Dart 异常）达到 `maxCrashCount` 次（默认 1 次）时，设备停用并拉黑该补丁，从下次冷启动起回到安装包自带的版本，避免用户反复崩溃。详见[崩溃保护](crash-protection-zh.md)。
- **并发防覆盖**：多台机器同时向同一存储桶发布时，以条件写入（Conditional Write）保证不会互相覆盖。
- **中断恢复**：`publish` 意外中断后，在同一项目中用相同参数重新运行即可完成未完成的发布。

## 关联阅读

- [轮换发布密钥](advanced-zh.md#轮换发布密钥)：publisher 私钥泄露或丢失时，用 root 私钥签署信任更新来更换，无需重新发版（前提是 App 已接入信任更新）。
- [清理历史补丁](advanced-zh.md#清理历史补丁)：删除发布存储中过期的历史补丁，释放空间。
- [自行分发清单](api-reference-zh.md#自行分发清单)：不走公开静态 CDN，通过自有的鉴权接口下发清单与补丁。
