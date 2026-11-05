<!-- ========================================== -->
<!-- doc/production-playbook-zh.md (简体中文)    -->
<!-- ========================================== -->

# 生产部署

[English](production-playbook.md) | **简体中文**

生产环境使用与[快速上手](getting-started-zh.md)相同的命令，区别在于基线和补丁存放在哪里、设备从哪里下载。完整的命令参数见 [CLI 参考](cli-zh.md)。

## 上线需要什么

开发时，`serve` 把补丁放在项目里，并通过 USB 交给手机。App 上线后，改为需要以下几样：

| 需要什么 | 用途 | 在哪里配置 |
|---|---|---|
| 发布存储，以及它的 HTTPS 地址 | 设备从这里下载补丁 | `flutter_patcher.yaml` 中的 `store`，以及传给 `checkUpdate` 的地址 |
| 基线存储 | 为线上版本生成补丁时要用到它的基线 | `flutter_patcher.yaml` 中的 `baseline_store` |
| 在发布的地方能拿到私钥 | 设备只安装签过名的补丁 | [机器与 CI 上的密钥](#机器与-ci-上的密钥) |
| Android release 包的网络权限 | `checkUpdate` 需要联网 | `android/app/src/main/AndroidManifest.xml` |

## 配置存储

**发布存储**存放设备要下载的内容：每个版本一份签名清单（`manifests/`），以及补丁文件（`objects/`）。`publish` 往里写，App 从里面读，所以同一个位置有两个地址：

| 地址 | 谁用 | 示例 |
|---|---|---|
| `flutter_patcher.yaml` 中的 `store` | `publish` 用来写入，需要写权限 | `s3://my-bucket/my-app` |
| 传给 `checkUpdate` 的地址 | App 用来读取，公开访问，不需要凭证 | `https://cdn.example.com/my-app` |

两个地址不能互相推出：存储桶通过哪个域名或 CDN 对外提供，只有你知道；写入用的凭证也绝不能放进 App。开发时，`serve` 一个命令同时扮演两边：写入 `.flutter_patcher/updates/`，并通过 `http://127.0.0.1:8686` 提供读取。

**基线存储**存放每个线上版本的构建记录。`patch` 和 `publish` 会读取它，设备从不访问。基线丢失的版本再也无法打补丁。

发布存储按下面任选一种方式：

| 方式 | `store` | 设备从哪里读取 |
|---|---|---|
| 对象存储，可配合 CDN | `s3://存储桶/前缀`：AWS S3，或 Cloudflare R2 等 S3 兼容服务（设置 `FLUTTER_PATCHER_S3_ENDPOINT`） | 存储桶的公开 HTTPS 地址，或你的 CDN 地址 |
| 你自己的 Web 服务器 | `file://` 加一个本地或网络目录 | 你的服务器：把这个目录复制上去，先复制 `objects/`，再复制 `manifests/`，不要复制 `catalog.json` |
| 你自己的接口 | 以上任一种，不对外公开 | 你的接口；App 把清单和补丁交给 [`applySignedManifest`](api-reference-zh.md#自行分发清单) |

**操作**（以对象存储为例）：

1. 在 `flutter_patcher.yaml` 中指定两个存储：

   ```yaml
   store: s3://my-bucket/my-app
   baseline_store: s3://my-bucket/baselines
   ```

2. 让发布存储可以通过 HTTPS 读取，直接开放或经由 CDN。权限和缓存设置见 [CLI 参考：存储要求](cli-zh.md#存储要求)。
3. 在 App 中把这个 HTTPS 地址传给 `checkUpdate`：

   ```dart
   await FlutterPatcher.checkUpdate('https://cdn.example.com/my-app');
   ```

**验证**：

- `dart run flutter_patcher doctor --baseline-store s3://my-bucket/baselines` 的 `baseline_store` 一项通过。
- `build` 不再输出 `WARNING: BASELINE_STORE_LOCAL`。
- 执行一次 `publish` 后，`<HTTPS 地址>/<输出中的 manifest>` 返回 `200`。

## 机器与 CI 上的密钥

`keys init` 把项目的公钥写入 `flutter_patcher.yaml`，这个文件应提交到 git。私钥保存在项目之外，即执行 `keys init` 的那台电脑的 `~/.flutter_patcher/keys/`。只有签名时才用到私钥，也就是 `publish`、`serve` 和 `trust sign`；生成补丁不需要：

| 谁 | 需要什么 |
|---|---|
| 生成补丁的任意机器 | 源码和基线存储的访问权限，不需要私钥 |
| 负责发布的一方 | publisher 和 patch 私钥、发布存储，以及基线存储的读权限 |
| 轮换 publisher 密钥 | root 私钥，平时离线保存 |

**备份**：`keys init` 之后立即运行 `dart run flutter_patcher keys export --out <文件>`，把文件保存在安全的地方。`publisher` 私钥丢失后可以用 root 私钥更换（见[进阶操作](advanced-zh.md#轮换发布密钥)）；`root` 或 `patch` 私钥丢失后，已上线的宿主无法再更换。

负责发布的一方用的就是这套私钥，下面几种方式都不会生成新密钥，按你在哪里发布选一种：

| 在哪里发布 | 私钥怎么到那里 |
|---|---|
| 执行 `keys init` 的那台电脑 | 已经在了，不用做任何事 |
| 另一台电脑 | 在原电脑上 `keys export --out <文件>`，再到这台电脑上 `keys import <文件>` |
| CI 服务，如果你在用（自动构建和发布的托管机器，例如 GitHub Actions） | 把 `keys export --base64 --without-root` 输出的一行文本保存为 CI 的 secret，以环境变量 `FLUTTER_PATCHER_KEYS` 提供给任务，然后运行 `publish --yes`。这里不带 root 私钥，发布用不到它 |
| KMS 等签名服务，适用于私钥不能以文件形式出现的场合 | 配置 `signing.command`，由签名服务代为签名，私钥始终不离开服务。见 [CLI 参考：私钥从哪里来](cli-zh.md#私钥从哪里来) |

**验证**：在负责发布的机器上运行 `dart run flutter_patcher keys status`，publisher 和 patch 两把私钥的来源都不是 `none`。

## 发布流程

**目标**：发布商店版本，之后用补丁修复它。

**操作**：

1. 构建 App，把输出目录中的 `app-release.apk`（或 `app-release.ipa`）提交商店，并在 git 中为源码打标签：

   ```bash
   dart run flutter_patcher build android    # build ios 需在 Apple Silicon Mac 上运行
   ```

2. 在该标签的源码上修复问题，不改 `version`，然后生成补丁：

   ```bash
   dart run flutter_patcher patch android    # patch ios 可在任一支持的电脑上运行
   ```

3. 发布。命令先显示预览，确认后才写入；没有人确认的场合（例如 CI）加 `--yes`：

   ```bash
   dart run flutter_patcher publish
   ```

**验证**：

- `build` 输出 `"status":"build_archived"`，`patch` 输出 `"status":"patch_created"`。
- `publish` 输出 `"status":"published"`、分配的 `patch_seq`（同一版本依次为 1、2、3……），以及清单在存储中的路径 `manifest`。
- `<你的 HTTPS 地址>/<manifest>` 返回 `200`。

为更早的线上版本打补丁时，检出该版本的标签，并用 `--version-code` 指定它的构建号。每个版本有各自的基线和各自的序号。

## 灰度发布

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

## 撤回补丁

**目标**：让有问题的补丁不再运行。两种方式选一种。

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

## 始终生效的保护

- **签名校验**：设备只加载签名、哈希和目标版本都校验通过的补丁。存储或 CDN 中被改动的内容会被拒绝。
- **防重放**：设备不会安装不大于已接受序号的补丁，已撤回的序号也不会再生效。
- **启动保护**：导致启动失败的补丁会在该设备上停用，下次冷启动运行安装包自带的版本。见[崩溃保护](crash-protection-zh.md)。
- **并发发布**：多台机器可以共享同一组存储，同时发布不会互相覆盖。
- **中断恢复**：`publish` 中途中断后，在同一项目中再次运行即可完成。

## 进阶操作

- [轮换发布密钥](advanced-zh.md#轮换发布密钥)：publisher 私钥丢失或泄露时，无需重新发布商店版本即可更换。
- [清理历史补丁](advanced-zh.md#清理历史补丁)：释放发布存储空间。
- [自行分发清单](api-reference-zh.md#自行分发清单)：设备必须通过你自己的接口下载时。
