# 崩溃保护

[English](crash-protection.md) | **简体中文**

> 决定启动失败几次后停用补丁，在手机上亲眼看到它生效，并在线上读取启动诊断。

你的补丁已经装到设备上，想知道补丁导致 App 启动失败时会发生什么。设备会停用并拉黑该补丁，从下次冷启动起运行安装包自带的版本。本页覆盖 Android 和 iOS 宿主。启动成功之后发生的错误在这里不会被检测到，所以这部分交给你的崩溃监控。

## 配置

**目标**：决定启动失败几次后停用补丁。

**步骤**：在 `main()` 中、`runApp()` 之前调用 `init`。下面是默认值，不带参数调用 `init()` 效果相同：

```dart
await FlutterPatcher.init(
  maxCrashCount: 1,                        // 启动失败几次后停用补丁
  verifyAfter: const Duration(seconds: 5), // 首帧之后 Dart 异常仍计入失败的时长
);
```

- `maxCrashCount` 大于 1 时能容忍一次其他原因导致的失败，例如与补丁无关的进程崩溃，但有问题的补丁会先导致这么多次启动失败才被停用。补丁代码开始运行之后抛出的 Dart 异常不计次数，补丁立即停用，见[失败之后](#失败之后)。小于 1 的值按 1 处理。
- 参数详情见 [`init`](api-reference-zh.md#init)。

**验证**：一次运行补丁的冷启动之后，`await FlutterPatcher.lastBootDiagnostic` 的 `status` 为 `patched`。

## 在真机上验证

**目标**：在线上依赖崩溃保护之前，亲眼看到有问题的补丁被停用。

**前提**：[快速上手](getting-started-zh.md)中的 App 已安装，它用 `checkUpdate` 检查更新、用 `applyPatch` 安装，`serve` 正在运行。

**步骤**：

1. 在 `main()` 的第一行加上 `throw StateError('crash test');`，运行 `dart run flutter_patcher patch android`，然后删除这一行。
2. 打开 App，让它安装该补丁：`serve` 输出 `A device downloaded 1-arm64-v8a.fptc`（你的文件名）。
3. 从最近任务中关闭 App 并重新打开。本次启动运行补丁并失败：App 退出或白屏。
4. 再次打开 App。

**验证**：

- App 运行安装包自带的版本；`lastBootDiagnostic` 的 `status` 为 `droppedCircuitBreaker`，`message` 为 `Bad state: crash test`。
- App 再次检查更新时，`serve` 输出 `A device checked for updates`，但不再输出 `A device downloaded`，因为设备已接受该文件的序号，并已拉黑该补丁。
- 之后生成的不含 `throw` 的补丁正常安装和运行。

## 什么算启动失败

首帧绘制完成，且之后 `verifyAfter` 内没有未捕获的 Dart 异常，本次启动即为成功。

| 情况 | 判定 |
|---|---|
| 首帧之前抛出未捕获的 Dart 异常 | 失败 |
| 首帧之后 `verifyAfter` 内抛出未捕获的 Dart 异常；只计 App 在前台的时间 | 失败 |
| 首帧之前进程崩溃、ANR 或初始化失败 | 失败，在下次启动时记录 |
| 首帧之前用户关闭 App，或系统回收进程 | Android 11 及以上：不算失败，因为系统记录了进程结束的原因。Android 10 及以下：算失败，因为无法与崩溃区分 |
| iOS 上首帧之前 App 被切到后台 | 不算失败：本次尝试暂停，App 回到前台后继续 |
| 首帧之后、补丁进程仍在运行时发生崩溃或 ANR | Android 11 及以上：失败，在下次启动时记录。Android 10 及以下和 iOS：无法检测，所以依靠你的崩溃监控 |
| 已安装的补丁在冷启动时未通过校验或无法加载，例如文件损坏 | 失败 |

## 失败之后

每个补丁单独统计连续启动失败的次数，启动成功一次即归零。

- **未达到 `maxCrashCount`**：下次启动仍尝试该补丁。诊断为 `bytecodeBootFailed`，SO 宿主为 `soBootFailed`。
- **达到 `maxCrashCount`**：补丁被停用，所以下次冷启动运行安装包自带的版本。补丁加入本机黑名单，所以 `applyPatch`、`applyPatchBytes`、`applyPatchFile` 再遇到同一个文件时返回 `blacklisted`。诊断为 `droppedCircuitBreaker`。
- **补丁代码开始运行之后**（安装补丁的资源或执行补丁的 `main()`）抛出未捕获的 Dart 异常时，该补丁立即被停用并拉黑，与 `maxCrashCount` 无关，因为补丁的代码已经运行过，可能已改变 App 的状态，再次尝试并不安全。诊断为 `droppedCircuitBreaker`。
- **SO 宿主上**，补丁的 `libapp.so` 已经加载、其余文件却加载失败时，该补丁立即被拉黑，与 `maxCrashCount` 无关，因为已加载的代码运行过一次，不能再运行。

## 熔断之后怎么办

黑名单只在记录它的设备上生效，所以文件仍在 App 获取它的位置，尚未尝试过它的设备仍会安装。监控中出现 `droppedCircuitBreaker` 时：

1. **撤回补丁**，让设备回到安装包自带的版本，或重新发布之前某个正常的补丁；两种做法见[补丁下发回滚](production-playbook-zh.md#补丁下发回滚)。使用[自定义下发](advanced-zh.md#由自家服务端自定义下发)时，把命令生成的文件交给 App。
2. **修复问题**，下发新补丁。

> **警告：不要重新发布有问题的补丁的输出**
>
> `publish --patch` 会用新序号重新封装它，对黑名单而言这是另一个文件，所以设备会再次安装并运行它。

## 其他会让补丁失效的情况

| 情况 | 结果 |
|---|---|
| 用户将 App 升级到新版本 | 旧版本的补丁不再生效；诊断为 `droppedVersionCodeMismatch` |
| 设备应用了序号大于该补丁的撤回文件 | 补丁被删除；当前进程继续运行原来的代码，下次冷启动运行安装包自带的版本 |
| App 调用了 `rollback()` | 补丁被删除，但不会被拉黑；之后只有序号更大的文件才能安装。见 [`rollback`](api-reference-zh.md#rollback) |
| 用户清除 App 数据或重新安装 App | 补丁和所有本机记录被清除 |

## 启动诊断

`FlutterPatcher.lastBootDiagnostic` 返回最近一次冷启动对补丁的处理结果。

- 本次启动运行补丁且首帧尚未绘制时，调用会等待首帧，最多 10 秒，所以返回的是本次启动而不是上一次的结果。
- 尚无任何记录时返回 `null`。

**上报异常启动**到你自己的监控：

```dart
final diag = await FlutterPatcher.lastBootDiagnostic; // 最近一次冷启动对补丁的处理结果
if (diag != null && !diag.isHealthy) {
  report('patch_boot', {                 // 发送到你自己的监控
    'status': diag.status.name,
    'patch': diag.patchVersion,
    'crashes': diag.crashCount,
    'message': diag.message,
  });
}
```

- 没有补丁的启动会保留之前的 `bytecodeBootFailed`、`soBootFailed`、`droppedCircuitBreaker` 或 `droppedVersionCodeMismatch` 记录，因为该记录说明了补丁没有运行的原因。
- 记录保留到下一次带补丁的启动，所以只想上报一次时，把 `recordedAt` 与上次上报的值比较。

| `status` | 含义 | `isHealthy` |
|---|---|:---:|
| `noPatch` | 没有安装补丁 | ✅ |
| `patched` | 补丁已加载，首帧已绘制 | ✅ |
| `bytecodeBootFailed` | 字节码补丁启动失败，尚未达到 `maxCrashCount` | ❌ |
| `soBootFailed` | SO 补丁启动失败，尚未达到 `maxCrashCount` | ❌ |
| `droppedCircuitBreaker` | 补丁达到 `maxCrashCount`，已停用并拉黑 | ❌ |
| `droppedVersionCodeMismatch` | App 已升级，所以旧补丁被丢弃 | ❌ |
| `hookInstallFailed` | 仅 Android SO 宿主：补丁加载机制设置失败。本次启动运行安装包自带的版本，补丁仍保持安装 | ❌ |
| `unknown` | 其他情况，见 `message` | ❌ |

`PatchBootDiagnostic` 的其他字段：

| 字段 | 类型 | 说明 |
|---|---|---|
| `patchVersion` | `String?` | 所涉及补丁的 `seq`，见[补丁文件](cli-zh.md#补丁文件) |
| `patchTargetVersionCode` | `int?` | 安装补丁时 App 的构建号 |
| `appVersionCode` | `int?` | 写入本记录时 App 的构建号 |
| `crashCount` | `int?` | 该补丁连续启动失败的次数 |
| `attemptedLoaderFields` | `List<String>?` | 出现 `hookInstallFailed` 时尝试过的加载器字段 |
| `recordedAt` | `DateTime` | 本记录的写入时间 |
| `message` | `String?` | 供开发者查看的说明，不要展示给用户 |

## 黑名单

```dart
final entries = await FlutterPatcher.blacklist; // 列出本机已拉黑的补丁
await FlutterPatcher.clearBlacklist();          // 清空黑名单并将失败次数归零
```

每个 `BlacklistEntry` 包含：

| 字段 | 类型 | 说明 |
|---|---|---|
| `version` | `String` | 补丁标识：`<宿主指纹>:<seq>:<补丁文件的 SHA-256>` |
| `reason` | `String` | 始终为 `BOOT_CRASH` |
| `blacklistedAt` | `DateTime` | 补丁被拉黑的时间 |

在测试时，或在排除失败原因之后，清空黑名单。
