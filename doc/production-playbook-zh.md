<!-- ========================================== -->
<!-- doc/production-playbook-zh.md (简体中文)   -->
<!-- ========================================== -->

# 生产部署

[English](production-playbook.md) | **简体中文**

生产环境与本地调试使用相同的命令，区别仅在于补丁的存储和分发位置。本文介绍上线所需的配置，以及灰度发布、撤回补丁等发布管理功能。完整的命令行参数见 [CLI 参考](cli-zh.md)。

## 配置存储

在 `flutter_patcher.yaml` 中指定两个存储位置：

```yaml
store: s3://my-bucket/my-app
baseline_store: s3://my-bucket/baselines
```

| 配置项 | 用途 | 支持的类型 |
|---|---|---|
| `store` | 发布存储，存放补丁和签名清单，供设备下载 | `s3://`、`file://` |
| `baseline_store` | 基线存储，存放每个线上版本的基线，生成补丁时使用 | `s3://`、HTTPS、`file://` |

将发布存储通过 HTTPS 对外提供访问（例如对象存储配合 CDN），然后在应用中使用该地址：

```dart
await FlutterPatcher.checkUpdate('https://cdn.example.com/my-app');
```

> 为线上版本生成补丁需要基线存储，发布补丁需要私钥，两者都请备份，见[机器与 CI 上的密钥](#机器与-ci-上的密钥)。

各存储类型的权限、协议和 CDN 缓存要求见 [CLI 参考：存储要求](cli-zh.md#存储要求)。

## 机器与 CI 上的密钥

`keys init` 把项目的公钥写入 `flutter_patcher.yaml`，这个文件应提交到 git。私钥保存在项目之外，即执行 `keys init` 的那台电脑的 `~/.flutter_patcher/keys/`。只有签名时才用到私钥，也就是 `publish`、`serve` 和 `trust sign`；生成补丁不需要：

| 谁 | 需要什么 |
|---|---|
| 生成补丁的任意机器 | 源码和基线存储的访问权限，不需要私钥 |
| 负责发布的一方 | publisher 和 patch 私钥、发布存储，以及基线存储的读权限 |
| 轮换 publisher 密钥 | root 私钥，平时离线保存 |

**备份**：`keys init` 之后立即运行 `dart run flutter_patcher keys export --out <文件>`，把文件保存在安全的地方。`root` 或 `patch` 私钥丢失后，已上线的宿主无法再更换。

负责发布的一方用的就是这套私钥，下面几种方式都不会生成新密钥，按你在哪里发布选一种：

| 在哪里发布 | 私钥怎么到那里 |
|---|---|
| 执行 `keys init` 的那台电脑 | 已经在了，不用做任何事 |
| 另一台电脑 | 在原电脑上 `keys export --out <文件>`，再到这台电脑上 `keys import <文件>` |
| CI 服务，如果你在用（自动构建和发布的托管机器，例如 GitHub Actions） | 把 `keys export --base64 --without-root` 输出的一行文本保存为 CI 的 secret，以环境变量 `FLUTTER_PATCHER_KEYS` 提供给任务，然后运行 `publish --yes`。这里不带 root 私钥，发布用不到它 |
| KMS 等签名服务，适用于私钥不能以文件形式出现的场合 | 配置 `signing.command`，由签名服务代为签名，私钥始终不离开服务。见 [CLI 参考：私钥从哪里来](cli-zh.md#私钥从哪里来) |

## 发布流程

1. 构建安装包并提交应用商店：

   ```bash
   dart run flutter_patcher build android
   ```

   基线会自动归档至基线存储。

2. 修复问题后生成补丁：

   ```bash
   dart run flutter_patcher patch android
   ```

   输出中的 `changed` 列出本次改动的内容，可据此确认补丁范围。

3. 发布补丁：

   ```bash
   dart run flutter_patcher publish
   ```

   命令会先显示预览，确认后才写入发布存储；在 CI 中使用 `--yes`。

建议为每个上架版本创建 Git Tag，生成补丁时基于对应 Tag 的源码修改，并保持 `pubspec.yaml` 中的版本号不变。为更早的线上版本发布补丁时，检出该版本的 Tag，并用 `--version-code` 指定其构建号。

## 安全与可靠性

以下机制默认启用，无需额外配置：

- **签名校验**：设备只加载经过签名且内容完整的补丁。存储或 CDN 中的内容被篡改时，设备会拒绝加载。
- **防回滚**：已撤回的补丁和比当前更旧的补丁不会被重新安装。
- **启动保护**：补丁导致启动失败时，应用在下次冷启动时运行安装包自带的版本，并在本机停用该补丁。详见[崩溃保护](crash-protection-zh.md)。
- **并发安全**：多台构建机可以共享同一组存储，同时发布时不会互相覆盖。
- **中断恢复**：发布过程中断后，重新执行 `publish` 即可完成本次发布。

## 灰度发布

补丁发布后，同一版本的所有设备都能检查到更新。如需按比例逐步放量，可在应用侧结合远程配置决定是否调用 `checkUpdate`：

```dart
if (userBucket(userId) < rolloutPercent) {
  final check = await FlutterPatcher.checkUpdate(url);
  if (check.hasUpdate) {
    await FlutterPatcher.applyPatch(check.patch!);
  }
}
```

逐步提高 `rolloutPercent`（例如 1% → 5% → 20% → 100%），每个阶段确认崩溃率和[启动诊断](crash-protection-zh.md#启动诊断)正常后再继续。

## 撤回补丁

```bash
dart run flutter_patcher publish --withdraw
```

撤回最近一次 `patch` 所属版本的全部已发布补丁。设备在 App 下次应用更新时移除被撤回的补丁，下次冷启动后恢复为安装包自带的版本。

- 只撤回到某个序号：使用 `--through <序号>`。
- 撤回其他版本的补丁：使用 `--patch <目录>` 指向该版本的一次 `patch` 输出。

撤回总是让设备回到安装包自带的版本：设备只保存一个补丁，而且不会回到更小的序号。如果想回到之前的某个补丁，重新发布那个补丁的输出即可。它会得到下一个序号，以普通更新的形式送达设备：

```bash
dart run flutter_patcher publish --patch .dart_tool/flutter_patcher/patches/<目录>
```

`patch` 输出保存在 `.dart_tool/flutter_patcher/patches/`，直到你删除它；如果输出已经不在，检出那个补丁的源码重新运行 `patch`。

撤回以普通更新的形式下发，应用对 `hasUpdate` 为 `true` 的结果调用 `applyPatch`（即上面示例中的用法）即可生效。之后发布的补丁会使用更大的序号。

## 进阶操作

- [轮换发布密钥](advanced-zh.md#轮换发布密钥)：发布密钥泄露或丢失时，无需重新发版即可更换。
- [清理历史补丁](advanced-zh.md#清理历史补丁)：释放发布存储空间。
