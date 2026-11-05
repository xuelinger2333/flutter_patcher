<!-- ========================================== -->
<!-- doc/production-playbook-zh.md (简体中文)    -->
<!-- ========================================== -->

# 生产部署

[English](production-playbook.md) | **简体中文**

生产环境使用与[快速上手](getting-started-zh.md)相同的命令，区别在于基线和补丁存放在哪里、设备从哪里下载。完整的命令参数见 [CLI 参考](cli-zh.md)。

## 检查单

**第一次用 flutter_patcher 发布商店版本之前**：

- [ ] `flutter_patcher.yaml` 中的 `store` 和 `baseline_store` 指向持久存储，`build` 不再输出 `WARNING: BASELINE_STORE_LOCAL`（见[配置存储](#配置存储)）。
- [ ] 已用 `keys export` 备份密钥，`flutter_patcher.yaml` 已提交到 git（见[机器与 CI 上的密钥](#机器与-ci-上的密钥)）。
- [ ] 发布存储通过 HTTPS 对外提供访问，App 把这个地址传给 `checkUpdate`。
- [ ] Android：release 包声明了 `android.permission.INTERNET`。
- [ ] 提交商店的安装包是 `flutter_patcher build` 的产物，对应的源码在 git 中打了标签。

**每次发布补丁之前**：

- [ ] 源码是该商店版本的标签加上这次修复，`pubspec.yaml` 中的 `version` 没有改动。
- [ ] `patch` 输出的 `changed` 只列出你想改的内容；如有 `warnings`，已逐条看过。
- [ ] 知道出问题时如何[撤回](#撤回补丁)。

## 配置存储

**目标**：基线和补丁保存在不依赖某台电脑的存储中，设备通过 HTTPS 下载补丁。

**操作**：

1. 在 `flutter_patcher.yaml` 中指定两个存储：

   ```yaml
   store: s3://my-bucket/my-app
   baseline_store: s3://my-bucket/baselines
   ```

   | 配置项 | 存放内容 | 支持的类型 |
   |---|---|---|
   | `store` | 设备下载的补丁和签名清单 | `s3://`、`file://` |
   | `baseline_store` | 每个线上版本的基线，`patch` 和 `publish` 都会读取 | `s3://`、HTTPS、`file://` |

2. 把发布存储通过 HTTPS 对外提供访问（例如对象存储配合 CDN），并在 App 中使用这个地址：

   ```dart
   await FlutterPatcher.checkUpdate('https://cdn.example.com/my-app');
   ```

各类型存储的权限、协议和 CDN 缓存设置见 [CLI 参考：存储要求](cli-zh.md#存储要求)。

**验证**：

- `dart run flutter_patcher doctor --baseline-store s3://my-bucket/baselines` 的 `baseline_store` 一项通过。
- `build` 不再输出 `WARNING: BASELINE_STORE_LOCAL`。

基线丢失的版本再也无法打补丁，基线存储要像备份一样对待。

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
