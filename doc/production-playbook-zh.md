<!-- ========================================== -->
<!-- doc/production-playbook-zh.md (简体中文)    -->
<!-- ========================================== -->

# 生产部署

[English](production-playbook.md) | **简体中文**

本文把你在本地验证过的补丁流程（见[快速上手](getting-started-zh.md)）搬到线上。命令完全相同。上线要做的是：把 `.fptc` 文件放到 App 能拿到的地方，保管好基线，并按需开启签名。全部参数见 [CLI 参考](cli-zh.md)。

## 前提

- 快速上手中的本地流程已经跑通。
- App 有办法拿到补丁文件：给内置下载器（`checkUpdate`）用的 HTTPS 地址，或者你自己的接口、推送等渠道，把文件交给 `applyPatchBytes` / `applyPatchFile`。

## 1. 确定 App 从哪里获取补丁文件

一个补丁就是一个文件，名为 `<version_code>-<flavor>-<channel>-<abi>.fptc`，例如 `7-default-production-arm64-v8a.fptc`。每个构建（versionCode、flavor、channel、ABI）有自己的文件名，同一构建的所有补丁都用这个名字：新的补丁或撤回文件会替换原文件。

**使用内置下载器**：

1. 在 `flutter_patcher.yaml` 中设置地址（项目还没有这个文件时新建）：

   ```yaml
   url: https://cdn.example.com/my-app
   ```

   `build` 把它写进 App；之后 `checkUpdate()` 请求 `https://cdn.example.com/my-app/<文件名>`。

2. 托管方必须满足：

   | 要求 | 原因 |
   |---|---|
   | HTTPS | 下载器只对 `127.0.0.1`/`localhost` 允许明文 HTTP |
   | `.fptc` 文件的缓存时间要短，例如 `Cache-Control: max-age=60` | 文件名不变，缓存过长会一直返回旧文件 |
   | 直接返回文件：`200`（范围请求可为 `206`），没有文件时 `404`，不重定向 | 下载器不跟随重定向；其他状态码都会让检查失败 |

   范围请求（Range）不是必需的：`checkUpdate` 请求前 146 字节，无论服务器返回多少，读到这些就停止。

**自己下发**：由你的服务端根据 [`FlutterPatcher.patchTarget`](api-reference-zh.md) 给出的信息（`fileName`、`versionCode`、`flavor`、`channel`、`abi`、`acceptedSeq`）选择文件，App 把字节交给 `applyPatchBytes`。这时传输安全由 App 负责，见[3. 可选：开启签名](#3-可选开启签名)。

无论哪种方式，都要确认 `android/app/src/main/AndroidManifest.xml` 声明了网络权限，release 构建需要它：

```xml
<uses-permission android:name="android.permission.INTERNET" />
```

## 2. 保管基线

`build` 为每次构建记录一份基线（编译产物、源码哈希、依赖、资源），这次构建的每个补丁都以它为准生成。默认只保存在项目的 `.flutter_patcher/baselines/` 中，`build` 会提示 `WARNING: BASELINE_STORE_LOCAL`。

把 `baseline_store` 指向持久的存储，例如私有的 S3 或 R2 前缀（存储要求与凭据见 [CLI 参考](cli-zh.md)）：

```yaml
baseline_store: s3://my-bucket/baselines
```

**验证**：`dart run flutter_patcher doctor --baseline-store s3://my-bucket/baselines` 通过，`build` 不再输出 `WARNING: BASELINE_STORE_LOCAL`。

**基线丢失时**：这次构建无法再打补丁（`patch` 报 `BASELINE_NOT_FOUND`）。只能发一版新的安装包来解决。

## 3. 可选：开启签名

推荐开启签名，默认不开启。

| 宿主 | 谁能在 App 中运行代码 |
|---|---|
| 不签名（默认） | 任何能把文件交给 App 的一方。内置下载器强制 HTTPS；App 自己获取文件时，传输安全由 App 负责 |
| 签名 | 只有持有补丁私钥的一方。存储、CDN、传输链路和 App 的获取方式都不需要可信 |

开启签名：在**要上线的那次构建之前**执行：

```bash
dart run flutter_patcher keys init
```

它生成一把补丁密钥：私钥保存在本机的 `~/.flutter_patcher/keys/<id>/keys.json`（Windows 上 `~` 是用户目录），公钥以 `trust.patch` 写入 `flutter_patcher.yaml`。此后构建的宿主只接受这把密钥签名的文件，`build` 不再输出 `WARNING: UNSIGNED`。宿主保持构建时的模式：已上线的不签名宿主仍然不签名，签名宿主也永远不接受未签名的文件。

签名需要封装文件的那台机器上有私钥。`patch` 和 `publish` 按以下顺序查找：

1. `--key-file <密钥包>`（仅 `publish`）
2. 环境变量 `FLUTTER_PATCHER_KEYS`，即 `keys export --base64` 输出的 base64 单行
3. `flutter_patcher.yaml` 中的 `signing.command`，即外部签名程序，例如 KMS（从 stdin 读取待签名字节，输出 base64 的 Ed25519 签名；`FLUTTER_PATCHER_SIGN_ROLE` 为 `patch`）
4. 本机密钥库 `~/.flutter_patcher/keys/`

用 `keys export --out <文件>` 和 `keys import <文件>` 在机器间转移密钥；`keys status` 显示会由哪个来源签名。机器上没有私钥时，`patch` 只写出草稿（`"file": null`，并附提示），再在有私钥的机器上执行 `publish --patch <输出目录>` 完成封装与签名。

**私钥丢失时**：用它构建的宿主无法再打补丁。从 `flutter_patcher.yaml` 中删除 `trust:` 一项，重新执行 `keys init`，再发一版用新密钥构建的安装包。

## 4. 构建并提交商店版本

```bash
dart run flutter_patcher build android    # build ios 必须在 Apple Silicon Mac 上运行
```

像平常一样把生成的 `app-release.apk`（或 `app-release.ipa`）提交到商店。

**验证**：输出 `"status":"build_archived"`；设置 `url` 后不再出现 `WARNING: URL_LOCAL`，设置 `baseline_store` 后不再出现 `WARNING: BASELINE_STORE_LOCAL`，开启签名后不再出现 `WARNING: UNSIGNED`。

## 5. 生成并发布补丁

1. 修改代码。不要改 `pubspec.yaml` 中的 `version`。
2. 生成补丁：

   ```bash
   dart run flutter_patcher patch android    # patch ios 可在任一支持的主机上运行，不需要 Mac
   ```

3. 发布到存储：

   ```bash
   dart run flutter_patcher publish
   ```

   `publish` 取最新的补丁输出（或 `--patch <目录>`），用新的序号重新封装（默认是当前 Unix 秒数，也可用 `--seq N` 指定），宿主签名时一并签名，然后把 `<文件名>.fptc` 写入存储。它会先显示摘要并等待输入 `y`；在 CI 等无人值守的环境中加 `--yes`。没有 `--yes` 又没有终端时只做预览（`"status":"preview"`），不写入任何内容。

4. 把文件放到 App 获取的地方。存储默认是 `.flutter_patcher/updates/`：把 `.flutter_patcher/updates/<文件名>.fptc` 上传到 `url`（设置了 `url` 时 `publish` 会给出这条提示）。在 `flutter_patcher.yaml` 中设置 `store: s3://my-bucket/my-app` 后，`publish` 通过 AWS CLI 直接写入存储桶（S3 兼容存储如 R2 用 `FLUTTER_PATCHER_S3_ENDPOINT` 指定地址）；再把这个前缀以 `url` 公开提供。自己下发的 App 从存储或补丁输出目录中取文件即可。

**验证**：

- `publish` 输出 `"status":"published"`、文件名 `file` 和序号 `seq`。
- `curl -sI <url>/<文件名>` 返回 `200`。
- 这次构建的 App 在下次检查时拿到补丁，下次冷启动起运行它；此时 `FlutterPatcher.currentVersion` 返回这个 `seq`。

| `publish` 的结果 | 含义与处理 |
|---|---|
| `"status":"already_published"` | 存储中已经是这个补丁，没有写入 |
| `PUBLISH_SEQUENCE_CONFLICT` | 存储中这次构建的文件序号不低于新序号，通常是某台电脑的时钟偏快。校正时钟，或按提示用 `--seq` 发布 |
| `PUBLISH_CONFLICT` | 发布过程中存储里的文件变了，例如另一台机器刚发布过。重新执行 `publish` |
| `KEYS_NOT_FOUND` | 宿主是签名的，而这台机器上没有对应的私钥，见[第 3 步](#3-可选开启签名) |

每个构建有自己的文件，多个线上版本的补丁可以并存。要给较早的线上版本打补丁，检出该版本的代码，并传入它的构建号：`patch android --version-code <构建号>`，再按上面的方法发布。

## 撤回与回退

| 目标 | 做法 |
|---|---|
| 撤回：设备回到安装包自带的版本 | `publish --withdraw`（针对最新补丁以外的构建时加 `--patch <目录>`）。它写出一个带新序号、不含 payload 的撤回文件。应用了它的设备删除补丁，下次冷启动运行安装包自带的版本 |
| 回到之前的好补丁 | `publish --patch .dart_tool/flutter_patcher/patches/<它的输出目录>`：旧补丁用新的、更大的序号重新封装，作为普通更新下发到设备 |
| 停止分发 | 不再提供文件（从托管处删除，或你的接口不再返回）。已安装补丁的设备不受影响；这不是撤回 |
| 单台设备 | 在 App 中调用 `FlutterPatcher.rollback()`：删除这台设备上的补丁，不拉黑 |

每次 `publish` 之后，按第 5 步上传新文件。重新上传旧的 `.fptc` 不会生效：它的序号不高于设备已经接受的序号。之前的补丁输出被删除时，检出那时的代码重新执行 `patch` 即可。

**设备如何判断**：设备只安装属于本构建、内容完整、（宿主签名时）签名有效、且序号高于此前接受过的所有文件的文件。补丁和撤回都在下次冷启动生效。

**验证**：

- 撤回：CLI 输出 `"action":"withdraw"`。冷启动后，`FlutterPatcher.currentVersion` 为 `null`，`lastBootDiagnostic` 为 `noPatch`。
- 回到之前的补丁：CLI 输出的 `seq` 高于问题补丁。冷启动后，`currentVersion` 为这个序号，运行的是之前的代码。

## 灰度发布

`url` 上的文件会到达这个构建中每一台检查更新的设备。要按比例或按用户发布，由 App 或你的服务端决定：在检查前加开关，或由服务端决定返回哪个文件。

```dart
// 灰度开关
if (userBucket(userId) < rolloutPercent) {
  final check = await FlutterPatcher.checkUpdate();
  if (check.hasUpdate) {
    await FlutterPatcher.applyPatch(check.patch!);
  }
}
```

- `userBucket(userId)`：对用户唯一标识取哈希后模 100，得到 0–99。
- `rolloutPercent`：由你的配置服务下发的比例。

两者都需要自己实现。扩大比例时关注崩溃率，以及 `isHealthy == false` 的[启动诊断](crash-protection-zh.md)所占比例。

## 从 1.0 升级

| 对象 | 1.1 的行为 |
|---|---|
| 已经用 1.0.0 上线的宿主 | 不受影响。给它们打补丁、发布、撤回只能用 flutter_patcher 1.0.0+1：在那个版本的代码中，`pubspec.yaml` 依赖 `flutter_patcher: 1.0.0+1`。1.1 读取它们的基线时报 `PATCH_BASELINE_INCOMPATIBLE` |
| 项目 | 照常可用：读取 `flutter_patcher.yaml` 中的 `trust.patch`（忽略 `root` 和 `publisher`），`url`、`store`、`baseline_store`、`signing.command` 和各条命令的含义不变。密钥库中 1.0 的密钥包按补丁公钥查找，可以直接使用。下一次 `build` 得到 1.1 宿主，用这把补丁密钥签名 |
| 存储 | 1.0 的 `manifests/`、`objects/` 和 `catalog.json` 保留，1.0.0 宿主仍读取它们。1.1 把 `.fptc` 文件写在存储根目录，与它们并列 |
| Dart API | 已删除：`SignedManifest`、`SignedUpdateResult`、`fetchSignedManifest`、`applySignedManifest`、`updatePublicationTrust`。改用 `applyPatchBytes`、`applyPatchFile` 或 `checkUpdate` |
| CLI | 已删除：`trust`、`publish --production` 与 `--request`（改为直接在存储中删除文件）、`keys import --rotate`、密钥角色 `root` 与 `publisher` |
| 显示的版本 | `currentVersion` 现在是文件的序号，即 Unix 时间戳 |

## 内置保护

- **完整性与目标校验**：设备检查每个文件的长度、格式、目标构建和 SHA-256 哈希，签名宿主还校验签名；传输中被篡改或在缓存中损坏的文件会被拒绝。
- **防降级与重放**：设备记录接受过的最高序号，只安装序号更高的文件，撤回或被替换的文件不会再次生效。
- **启动熔断**：补丁导致启动失败（首帧前崩溃或 ANR，或首帧后 `verifyAfter` 内出现未捕获的 Dart 异常）达到 `maxCrashCount` 次（默认 1 次）时，设备关闭并拉黑该补丁，从下次冷启动起运行安装包自带的版本。见[崩溃保护](crash-protection-zh.md)。
- **并发不覆盖**：`publish` 只在存储中的文件期间未变化时替换它（否则报 `PUBLISH_CONFLICT`），且只用更高的序号替换。

## 延伸阅读

- [CLI 参考](cli-zh.md)：全部命令、参数和 `flutter_patcher.yaml` 设置。
- [API 参考](api-reference-zh.md)：`patchTarget`、`inspectPatch`、`applyPatchBytes`、`applyPatchFile`、`checkUpdate`。
- [错误码与排障](troubleshooting-zh.md)：错误码与恢复办法。
