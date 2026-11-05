<!-- ========================================== -->
<!-- doc/production-playbook-zh.md (简体中文)    -->
<!-- ========================================== -->

# 生产部署

[English](production-playbook.md) | **简体中文**

从本地跑通（[快速上手](getting-started-zh.md)）到 App 上线的最短路径。命令和快速上手相同：`publish` 仍然写到项目里，你把它写出的内容上传到自己选的 HTTPS 地址，设备从那里下载。

标有 **按需替换** 的地方是你的环境可能不同之处，其他做法见[按需替换](#按需替换)。完整的命令参数见 [CLI 参考](cli-zh.md)。

## 开始之前

本文假设：

- 项目已经按快速上手在本地跑通，包括 `keys init`。
- 有一个你能上传文件的 HTTPS 地址：对象存储加 CDN、自己的 Web 服务器或任意静态托管都可以。它必须直接返回文件、不做重定向，并且不能长时间缓存 `manifests/`，见 [CLI 参考：存储要求](cli-zh.md#存储要求)。

## 第 1 步：备份密钥

**目标**：保管好给补丁签名的密钥。设备只安装用它们签过名的补丁。

`keys init` 已经把公钥写入 `flutter_patcher.yaml`（这个文件要提交到 git），私钥保存在那台电脑的 `~/.flutter_patcher/keys/`。

**操作**：

```bash
dart run flutter_patcher keys export --out <文件>
```

把文件保存在这台电脑以外的安全位置。`root` 或 `patch` 私钥丢失后，已上线的 App 无法再更换；`publisher` 私钥丢失后可以用 root 私钥更换（见[进阶操作](advanced-zh.md#轮换发布密钥)）。

> **按需替换**：在另一台电脑、CI 上发布，或通过 KMS 等签名服务签名：[在别的机器或 CI 上发布](#在别的机器或-ci-上发布)。

**验证**：`dart run flutter_patcher keys status` 中 publisher 和 patch 两把私钥的来源都不是 `none`。

## 第 2 步：让 App 指向你的地址

**目标**：让 release 包从你的地址检查补丁，而不是从 `serve`。

**操作**：

1. 定好第 5 步要上传到的地址，例如 `https://cdn.example.com/my-app`。
2. 把快速上手中 `checkUpdate` 的 `http://127.0.0.1:8686` 换成这个地址：

   ```dart
   final check = await FlutterPatcher.checkUpdate('https://cdn.example.com/my-app');
   ```

3. 确认 `android/app/src/main/AndroidManifest.xml` 里仍有快速上手中添加的网络权限；没有它，release 包无法联网。

> **按需替换**：先只让一部分用户安装补丁：[灰度发布](#灰度发布)。

## 第 3 步：发布商店版本

**目标**：把一个之后能打补丁的版本提交到应用商店。

**操作**：

1. 构建：

   ```bash
   dart run flutter_patcher build android    # build ios 需在 Apple Silicon Mac 上运行
   ```

2. 把输出目录中的 `app-release.apk`（或 `app-release.ipa`）提交到商店。
3. 在 git 中为源码打标签。这个版本的补丁都从这份源码生成。

**验证**：

- `build` 输出 `"status":"build_archived"`。
- 同时输出 `WARNING: BASELINE_STORE_LOCAL`：这个版本的基线保存在项目的 `.flutter_patcher/baselines/` 里。请保管好这个目录，见[保管好这两个目录](#保管好这两个目录)。

## 第 4 步：发布补丁

**目标**：为线上版本的修复签名并编号。

**操作**：

1. 在打了标签的源码上修复问题，不改 `pubspec.yaml` 中的 `version`。
2. 生成补丁：

   ```bash
   dart run flutter_patcher patch android    # patch ios 可在任一支持的电脑上运行
   ```

3. 发布。命令先显示预览，确认后才写入；没有人确认的场合（例如 CI）加 `--yes`：

   ```bash
   dart run flutter_patcher publish
   ```

**验证**：

- `patch` 输出 `"status":"patch_created"`。
- `publish` 输出 `"status":"published"`、分配的 `patch_seq`（同一版本依次为 1、2、3……），以及清单路径 `manifest`，例如 `manifests/<hash>.json`。

> **按需替换**：给比最新版本更早的线上版本打补丁：[给更早的版本打补丁](#给更早的版本打补丁)。

## 第 5 步：上传

**目标**：让设备能下载到刚发布的补丁。

`publish` 写到了项目的 `.flutter_patcher/updates/` 里，设备需要其中两个文件夹。

**操作**：把它们上传到第 2 步定好的地址，保持文件夹名不变，按这个顺序：

1. `objects/`
2. `manifests/`

不要上传 `catalog.json` 和 `.publish.lock`：它们是 CLI 自己的记录，设备用不到。以后每次 `publish`（包括撤回）之后都要再上传一次。

顺序不能反：清单先于补丁上传时，设备会按清单去下载一个还不存在的文件，这次检查失败，下次检查才成功。

> **按需替换**：让 `publish` 直接写入存储桶，省掉上传这一步：[让 publish 直接写入存储桶](#让-publish-直接写入存储桶)。

**验证**：`<你的地址>/<publish 输出中的 manifest>` 返回 `200`。在装了这个版本的手机上，下次检查时应用补丁，下次冷启动后生效。

## 补丁出问题时

**目标**：让有问题的补丁不再运行。两种方式选一种，然后按第 5 步上传。

**方式一：让设备回到安装包自带的版本。**

```bash
dart run flutter_patcher publish --withdraw
```

撤回最近一次 `patch` 输出所属版本的全部已发布补丁。`--through <序号>` 只撤回到该序号；`--patch <目录>` 通过另一个版本的 `patch` 输出指定那个版本。

**方式二：让设备回到之前某个正常的补丁。** 重新发布那个补丁的输出。它会得到下一个序号，以普通更新的形式送达设备：

```bash
dart run flutter_patcher publish --patch .dart_tool/flutter_patcher/patches/<目录>
```

`patch` 输出保存在 `.dart_tool/flutter_patcher/patches/`，直到你删除它；输出已经不在时，检出那个补丁的源码重新运行 `patch`。不要重新发布有问题的那个补丁：它会得到新序号，设备会再次安装它。

两种方式都以普通更新的形式送达：App 对 `hasUpdate` 为 `true` 的 `checkUpdate` 结果调用 `applyPatch` 时生效，在下次冷启动时体现。设备只保存一个补丁，而且不会回到更小的序号，所以要回到之前的补丁，只能重新发布它。

**验证**：

- 方式一：`publish` 输出 `"action":"withdraw"`；设备下次冷启动后，`FlutterPatcher.currentVersion` 为 `null`，`lastBootDiagnostic` 为 `noPatch`。
- 方式二：`publish` 输出的 `patch_seq` 大于问题补丁的序号；设备下次冷启动后，`currentVersion` 为这个序号。

## 保管好这两个目录

两个目录都在项目里，请提交到 git 或纳入备份。

| 目录 | 存放什么 | 丢失后 |
|---|---|---|
| `.flutter_patcher/baselines/` | 每个线上版本的构建记录 | 丢失前构建的版本再也无法打补丁 |
| `.flutter_patcher/updates/` | 要上传的内容，以及记录所有已发布序号的 `catalog.json` | 序号会从 1 重新开始，而设备会忽略不大于已装补丁序号的补丁。下一个补丁用 `--seq` 指定一个比之前发布或撤回过的都大的序号发布，例如 `publish --seq 100` |

## 按需替换

### 让 publish 直接写入存储桶

`publish` 可以自己写入 AWS S3 或 Cloudflare R2 等 S3 兼容服务。这样不需要上传这一步，发布记录也保存在桶里，多台机器和 CI 可以发布到同一个地方。

**操作**：

1. 在每台负责发布的电脑上安装 AWS CLI，并登录有该存储桶写权限的账号。使用 S3 兼容服务时，还要把环境变量 `FLUTTER_PATCHER_S3_ENDPOINT` 设为它的服务地址。权限要求见 [CLI 参考：存储要求](cli-zh.md#存储要求)。
2. 在 `flutter_patcher.yaml` 中填写两个存储：

   ```yaml
   store: s3://my-bucket/my-app
   baseline_store: s3://my-bucket/baselines
   ```

3. 只把 `my-app` 这个前缀设为公开，第 2 步用它的 HTTPS 地址。基线保持私有。

`store` 是 `publish` 写入的地址，要用你的凭证；HTTPS 地址是设备读取同一批文件的地址，不需要凭证。

**验证**：`dart run flutter_patcher doctor --baseline-store s3://my-bucket/baselines` 的 `baseline_store` 一项通过，并且 `build` 不再输出 `WARNING: BASELINE_STORE_LOCAL`。

### 通过你自己的接口下发

设备必须通过你自己的接口下载时，App 从接口取得清单和补丁，交给 [`applySignedManifest`](api-reference-zh.md#自行分发清单)。发布方式不变，只是由你的接口而不是公开地址提供这些文件。

### 在别的机器或 CI 上发布

只有签名时才用到私钥，也就是 `publish`、`serve` 和 `trust sign`；生成补丁不需要：

| 谁 | 需要什么 |
|---|---|
| 生成补丁的任意机器 | 源码和基线，不需要私钥 |
| 负责发布的一方 | publisher 和 patch 私钥、基线，以及 `.flutter_patcher/updates/` 或存储桶 |
| 轮换 publisher 密钥 | root 私钥，平时离线保存 |

有多台机器发布时，请[让 publish 直接写入存储桶](#让-publish-直接写入存储桶)，这样它们共用同一份序号记录。

负责发布的一方用的就是这套私钥，下面几种方式都不会生成新密钥：

| 在哪里发布 | 私钥怎么到那里 |
|---|---|
| 另一台电脑 | 在原电脑上 `keys export --out <文件>`，再到这台电脑上 `keys import <文件>` |
| CI 服务（自动构建和发布的托管机器，例如 GitHub Actions） | 把 `keys export --base64 --without-root` 输出的一行文本保存为 CI 的 secret，以环境变量 `FLUTTER_PATCHER_KEYS` 提供给任务，然后运行 `publish --yes`。这里不带 root 私钥，发布用不到它 |
| KMS 等签名服务，适用于私钥不能以文件形式出现的场合 | 配置 `signing.command`，由签名服务代为签名，私钥始终不离开服务。见 [CLI 参考：私钥从哪里来](cli-zh.md#私钥从哪里来) |

**验证**：在负责发布的机器上运行 `dart run flutter_patcher keys status`，publisher 和 patch 两把私钥的来源都不是 `none`。

### 灰度发布

**目标**：先让一部分用户安装补丁，确认正常后再扩大范围。

补丁发布后，同一版本的所有设备都能检查到它。由 App 决定哪些用户去检查，例如根据远程配置：

```dart
if (userBucket(userId) < rolloutPercent) {
  final check = await FlutterPatcher.checkUpdate(url);
  if (check.hasUpdate) {
    await FlutterPatcher.applyPatch(check.patch!);
  }
}
```

`userBucket` 和 `rolloutPercent` 由你实现：前者为每个用户给出一个固定的 0–99 的数，后者来自远程配置。

**操作**：逐步提高 `rolloutPercent`，例如 1% → 5% → 20% → 100%。

**验证**：每次提高之前，查看崩溃率，以及[启动诊断](crash-protection-zh.md#启动诊断)中 `isHealthy` 为 `false` 的比例。

### 给更早的版本打补丁

检出那个版本的标签，修复后生成补丁时指定它的构建号：

```bash
dart run flutter_patcher patch android --version-code <构建号>
```

然后按第 4、5 步发布并上传。每个版本有各自的基线和各自的序号。

## 始终生效的保护

- **签名校验**：设备只加载签名、哈希和目标版本都校验通过的补丁。托管服务或 CDN 上被改动的内容会被拒绝。
- **防重放**：设备不会安装不大于已接受序号的补丁，已撤回的序号也不会再生效。
- **启动保护**：导致启动失败的补丁会在该设备上停用，下次冷启动运行安装包自带的版本。见[崩溃保护](crash-protection-zh.md)。
- **并发发布**：多台机器发布到同一个存储桶时不会互相覆盖。
- **中断恢复**：`publish` 中途中断后，在同一项目中再次运行即可完成。

## 进阶操作

- [轮换发布密钥](advanced-zh.md#轮换发布密钥)：publisher 私钥丢失或泄露时，无需重新发布商店版本即可更换。
- [清理历史补丁](advanced-zh.md#清理历史补丁)：释放发布存储空间。
- [自行分发清单](api-reference-zh.md#自行分发清单)：设备必须通过你自己的接口下载时。