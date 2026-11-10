# 生产部署

[English](production-playbook.md) | **简体中文**

在[快速上手](getting-started-zh.md)中，有三项配置只适用于开发。在构建要上线的版本之前把三项都换掉，因为地址和签名会随这次构建进入 App，基线在构建时保存。

| 配置 | 开发时 | 上线时 | `build` 的警告 | 步骤 |
|---|---|---|---|---|
| 更新地址 | App 向本机的 `serve` 要补丁 | App 向你的 HTTPS 服务器要补丁 | 无 | [1](#1-确定-app-从哪里获取补丁文件) |
| 基线存储 | 基线只保存在项目目录中 | 基线保存在持久存储中 | `BASELINE_STORE_LOCAL` | [2](#2-保管基线) |
| 签名 | App 安装任何补丁文件 | App 只安装你签名的文件 | `UNSIGNED` | [3](#3-开启签名) |

然后构建并发布商店版本（第 4 步），再向它下发补丁（第 5 步）。用到的命令与快速上手相同，选项见 [CLI 参考](cli-zh.md)。

## 1. 确定 App 从哪里获取补丁文件

App 获取补丁文件的方式有两种：

| 方式 | App 调用 | 你需要提供 |
|---|---|---|
| 内置下载器 | `checkUpdate` 和 `applyPatch` | 一个提供补丁文件的 HTTPS 地址 |
| 自定义下发 | `applyPatchBytes` 或 `applyPatchFile` | 你自己的渠道（例如自有接口），以及获取文件的代码 |

### 使用内置下载器

1. 把地址传给 `checkUpdate`：

   ```dart
   final check = await FlutterPatcher.checkUpdate(url: 'https://cdn.example.com/my-app');
   ```

   之后 App 请求 `<url>/<fileName>`，例如 `https://cdn.example.com/my-app/7-arm64-v8a.fptc`，其中 `<fileName>` 是 `patch` 为该构建的补丁文件起的名字。

2. 确认服务器满足以下要求。完整列表见[下载服务器](cli-zh.md#下载服务器)。

   | 要求 | 原因 |
   |---|---|
   | HTTPS | 下载器只对 `127.0.0.1` 和 `localhost` 接受明文 HTTP |
   | `.fptc` 文件的缓存时间要短，例如 `Cache-Control: max-age=60` | 新补丁沿用同一个文件名，缓存时间长时会一直提供旧文件 |
   | 有文件时返回 `200`（范围请求返回 `206`），没有文件时返回 `404` | 下载器不跟随重定向，其他任何状态码（例如私有 S3、R2 存储桶对不存在的对象返回的 `403`）都会让 `checkUpdate` 抛出异常 |

### 使用自定义下发

App 把 [`patchTarget`](api-reference-zh.md#patchtarget) 的字段发给你的服务端，服务端返回文件，App 用 `applyPatchBytes` 安装。App 侧的代码和服务端的做法见[由自家服务端自定义下发](advanced-zh.md#由自家服务端自定义下发)。

## 2. 保管基线

`patch` 生成补丁时，把你的代码与 `build` 为该构建保存的基线对比。默认情况下，`build` 只把基线保存在项目的 `.flutter_patcher/baselines/` 中，重新检出的代码或另一台电脑上都没有它。把 `baseline_store` 指向一个持久存储，并让每台运行 `patch` 的电脑都能读取，例如私有的 S3 或 R2 前缀。在 `flutter_patcher.yaml` 中设置：

```yaml
baseline_store: s3://my-bucket/baselines
```

各类存储的要求和凭据见[基线存储](cli-zh.md#基线存储)。

**验证**：`dart run flutter_patcher doctor --baseline-store s3://my-bucket/baselines` 通过，`build` 不再输出 `WARNING: BASELINE_STORE_LOCAL`。

> **警告：基线丢失后，该构建无法再打补丁**
>
> 此时 `patch` 以 `BASELINE_NOT_FOUND` 失败，而且基线无法重新生成。修复该构建的唯一办法是发布新的商店版本。

## 3. 开启签名

不签名时，App 安装为它这个构建生成的任何完整补丁文件，所以能在传输途中改动文件的人，就能在 App 中执行代码。签名后，App 只安装用你的私钥签名的文件。

`init` 已经生成了项目的补丁密钥：公钥是 `flutter_patcher.yaml` 中的 `trust.patch`，私钥在运行 `init` 的那台电脑的密钥库中。是否签名在构建时写进 App，所以要在构建上线版本之前打开：

```yaml
trust:
  patch: <init 写入的公钥>
  enabled: true
```

此后构建的每个 App 只接受用这把密钥签名的文件，`build` 也不再输出 `WARNING: UNSIGNED`。之前构建的 App 仍然不签名。

### 在其他电脑上签名

`patch` 和 `publish` 在运行它们的电脑上签名，所以那台电脑需要私钥：

- 另一台电脑：在这里运行 `keys export --out <file>`，在那台电脑上运行 `keys import <file>`。
- CI：设置 `FLUTTER_PATCHER_KEYS`，见[CI 中的密钥](advanced-zh.md#ci-中的密钥)。
- KMS 或签名服务：见[用 KMS 或签名服务签名](advanced-zh.md#用-kms-或签名服务签名)。

`keys status` 显示会用哪个来源签名。在没有私钥的电脑上，`patch` 输出 `"file":null`，不写出补丁文件：导入私钥后重新运行 `patch`。

> **警告：私钥丢失或泄露后，需要发布新的商店版本**
>
> 用丢失的私钥构建的 App 不再接受任何新的补丁文件，因为只有这把私钥能为它们签名。用泄露的私钥构建的 App 会运行持有者签名的任何文件。两种情况都要删除 `trust:`，运行 `init` 生成新密钥，设置 `trust.enabled: true`，并发布新的商店版本。

## 4. 构建并提交商店版本

```bash
dart run flutter_patcher build android   # build ios 需在 Apple Silicon Mac 上运行
```

把输出目录中的 `app-release.apk`（或 `app-release.ipa`）提交到商店。

**验证**：`build` 输出 `"status":"build_archived"`，并且不再出现 `BASELINE_STORE_LOCAL` 和 `UNSIGNED` 两条警告。

## 5. 生成并分发补丁

1. 修复代码。不要修改 `pubspec.yaml` 中的 `version`，因为 `patch` 按构建号查找构建。
2. 生成补丁：

   ```bash
   dart run flutter_patcher patch android   # patch ios 可在任何受支持的电脑上运行
   ```

   输出中的 `file` 是补丁文件的路径。App 是签名的，文件就是签名的。

3. 以原文件名把这个文件上传到 `<url>`，或交给你的自定义下发。

**验证**：`curl -sI <url>/<fileName>` 返回 `200`。该构建的 App 在下次检查时安装补丁，从下次冷启动开始运行它；之后 `FlutterPatcher.currentVersion` 返回该文件的 `seq`。

要为更早的线上版本打补丁，切换到它的代码，运行 `patch android --version-code <它的构建号>`。每个构建的文件名不同，所以多个线上版本的补丁不会互相替换。

### 可选：用 `publish` 写入存储

开发时，`serve` 把最新的 `patch` 输出直接提供给手机；上线后，由 `publish` 把它写入存储，再由你的服务器提供给 App。

```bash
dart run flutter_patcher publish
```

确认显示的内容后输入 `y`。输出 `"status":"published"` 即成功，其他结果见[排障](troubleshooting-zh.md)。

| `flutter_patcher.yaml` 中的 `store` | `publish` 写到哪里 | 之后要做的 |
|---|---|---|
| 不设置（默认） | 本机的 `.flutter_patcher/updates/` | 把其中的文件上传到 `<url>` |
| `s3://my-bucket/my-app` | 该存储桶，见[发布到 S3](advanced-zh.md#发布到-s3) | 无，只要 `<url>` 提供这个存储桶中的文件 |

- 与直接上传 `patch` 的输出相比，`publish` 按发布时间重新编号，所以最后发布的文件总是设备会安装的文件。
- 在 CI 中加 `--yes`，因为没有终端时 `publish` 只预览（`"status":"preview"`），不写入任何内容。

## 补丁下发回滚

| 目标 | 做法 |
|---|---|
| 让设备恢复运行安装包自带的版本 | 执行 `patch android --withdraw`，按分发补丁的方式分发它输出的文件；或执行 `publish --withdraw`，把撤回文件写入存储 |
| 恢复到之前可用的补丁 | 执行 `publish --patch .dart_tool/flutter_patcher/patches/<它的输出目录>`：旧补丁以新的、更大的序号重新封装，作为普通更新到达设备 |
| 停止分发某个补丁 | 从服务器删除文件，或让服务端不再返回它。已安装该补丁的设备继续运行它，要从这些设备上移除补丁，需下发撤回文件 |
| 从单台设备上移除补丁 | 在 App 中调用 `FlutterPatcher.rollback()` |

- 针对更早的构建或其他输出目录时的选项，见 [`patch`](cli-zh.md#patch) 和 [`publish`](cli-zh.md#publish)。
- 每次执行 `patch --withdraw` 或 `publish` 之后，按[第 5 步](#5-生成并分发补丁)分发新文件。
- 重新上传旧的 `.fptc` 不会生效，因为设备只安装序号高于其已接受的所有文件的文件。完整规则见[设备接受哪些文件](api-reference-zh.md#设备接受哪些文件)。
- 补丁和撤回都在下次冷启动时生效。

**验证**：

- 撤回：`patch --withdraw` 输出 `"status":"withdrawal_created"`；`publish --withdraw` 输出 `"action":"withdraw"`。冷启动后，`FlutterPatcher.currentVersion` 为 `null`，`lastBootDiagnostic` 的 `status` 为 `noPatch`。
- 恢复到之前的补丁：CLI 输出的 `seq` 高于问题补丁的序号。冷启动后，`currentVersion` 为该序号，运行的是之前的代码。

## 灰度发布

`url` 上的文件会到达该构建中每一台检查更新的设备，所以按比例或按用户发布由 App 或你的服务端决定：在 App 中为检查加开关，或由服务端决定返回哪个文件。

```dart
// 仅对灰度比例内的用户检查补丁
if (userBucket(userId) < rolloutPercent) {
  final check = await FlutterPatcher.checkUpdate();
  if (check.hasUpdate) {
    await FlutterPatcher.applyPatch(check.patch!);
  }
}
```

- `userBucket(userId)`：由你实现的函数，对用户唯一标识取哈希后模 100，得到 0–99。
- `rolloutPercent`：由你的配置服务下发的比例。

扩大比例时，关注崩溃率，以及 `isHealthy == false` 的[启动诊断](crash-protection-zh.md#启动诊断)所占比例。

## 相关

- [CLI 参考](cli-zh.md)：全部命令、参数和 `flutter_patcher.yaml` 设置。
- [API 参考](api-reference-zh.md)：`patchTarget`、`inspectPatch`、`applyPatchBytes`、`applyPatchFile`、`checkUpdate`。
- [错误码与排障](troubleshooting-zh.md)：错误码与恢复办法。
- [崩溃保护](crash-protection-zh.md)：补丁导致启动失败时，设备如何停用它。
- [安全模型](architecture-zh.md#安全模型)：设备安装文件之前检查什么。
- [从 1.0 升级](upgrading-zh.md)：已用 flutter_patcher 1.0.0 上线的 App 如何继续打补丁。
