<!-- ========================================== -->
<!-- doc/crash-protection-zh.md (简体中文)       -->
<!-- ========================================== -->

# 崩溃保护

[English](crash-protection.md) | **简体中文**

补丁导致 App 启动失败时，设备会停用这个补丁，从下次冷启动起运行安装包自带的版本。无需配置即可生效；本文说明如何调整它、如何亲手验证它，以及上线后如何观察它。

## 配置

**目标**：决定失败几次后停用补丁。

**操作**：在 `main()` 中、`runApp()` 之前调用 `init`。下面是默认值，不带参数调用 `init()` 效果相同：

```dart
await FlutterPatcher.init(
  maxCrashCount: 1,                        // 失败几次后停用补丁
  verifyAfter: const Duration(seconds: 5), // 首帧之后，Dart 异常仍计入失败的时长
);
```

调大 `maxCrashCount` 可以容忍偶发的失败，但有问题的补丁也会让用户多经历几次失败的启动。没有特别理由时保持默认值。

**验证**：一次运行补丁的冷启动之后，`await FlutterPatcher.lastBootDiagnostic` 的 `status` 为 `patched`。

## 在真机上验证

**目标**：上线前亲眼看到有问题的补丁被停用。

**前置条件**：[快速上手](getting-started-zh.md)中的 App 用 `checkUpdate` 检查更新、用 `applyPatch` 安装，`serve` 正在运行。

**操作**：

1. 在 `main()` 的第一行加上 `throw StateError('crash test');`，运行 `dart run flutter_patcher patch android`，然后删掉这一行。
2. 打开 App，让它安装这个补丁：`serve` 输出 `A device downloaded <文件名>`，例如 `A device downloaded 1-default-production-arm64-v8a.fptc`。
3. 划掉 App 再打开：这次启动运行补丁并失败，App 可能退出或白屏。
4. 再打开一次 App。

**验证**：

- App 运行的是安装包自带的版本；`lastBootDiagnostic` 的 `status` 为 `droppedCircuitBreaker`，`message` 为 `Bad state: crash test`。
- App 再次检查更新时，`serve` 输出 `A device checked for updates`，但不再输出 `A device downloaded`：设备已接受过这个文件的序号，并已拉黑这个补丁。
- 之后生成的正常补丁照常安装和运行。

## 什么算启动失败

首帧绘制完成，并且之后 `verifyAfter` 内没有未捕获的 Dart 异常，这次启动就算成功。

| 情况 | 判定 |
|---|---|
| 首帧之前抛出未捕获的 Dart 异常 | 失败 |
| 首帧之后 `verifyAfter` 内（只计 App 在前台的时间）抛出未捕获的 Dart 异常 | 失败 |
| 首帧之前进程崩溃、ANR 或初始化失败 | 失败，下次启动时判定 |
| 首帧之前用户划掉 App、系统回收内存 | Android 11 及以上不算失败；更低版本无法区分，会算作失败 |
| iOS 上首帧之前 App 被切到后台 | 不算失败 |
| 首帧之后、补丁进程仍在运行时发生崩溃或 ANR | Android 11 及以上：失败，下次启动时判定。Android 10 及以下和 iOS：检测不到，请依靠你的崩溃监控 |
| 已安装的补丁没有通过再次检查或无法加载（例如文件损坏） | 失败 |

Android 11 及以上通过系统的 `ApplicationExitInfo` 获取补丁进程的结束原因，只有崩溃、原生崩溃、ANR 和初始化失败才计数。

## 失败之后

每个补丁有自己的失败计数。未达到 `maxCrashCount` 时，下次启动仍会尝试这个补丁，诊断为 `bytecodeBootFailed`（SO 宿主为 `soBootFailed`）。达到 `maxCrashCount` 时：

1. 补丁被停用，下次冷启动运行安装包自带的版本；
2. 补丁加入本机黑名单，之后 `applyPatchBytes`、`applyPatchFile`、`applyPatch` 再遇到同一个文件会返回 `blacklisted`；
3. 启动诊断为 `droppedCircuitBreaker`。

SO 宿主上，如果补丁的 `libapp.so` 已经加载、其余部分却加载失败，补丁会被立即拉黑，不受 `maxCrashCount` 影响。

## 熔断之后怎么办

黑名单只在本机生效：文件仍在 App 获取它的地方，还没试过它的设备照样会安装。监控中出现 `droppedCircuitBreaker` 时：

1. 停止有问题的补丁：用 `publish --withdraw` 发布撤回，让设备回到安装包自带的版本；或用 `publish --patch <它的输出目录>` 重新发布之前某个正常补丁的输出，它会以新序号重新封装。App 用其他方式获取文件时，把这一步写入存储的文件交给 App。见[生产部署](production-playbook-zh.md)。
2. 修复问题，发布新补丁。

不要重新发布有问题的那个补丁的输出：它会得到新序号，对黑名单来说是另一个文件，设备会再次安装它。

## 其他会让补丁失效的情况

| 情况 | 结果 |
|---|---|
| 用户把 App 升级到新版本 | 旧版本的补丁不再生效，诊断为 `droppedVersionCodeMismatch` |
| 设备应用了序号大于该补丁的撤回（`publish --withdraw`） | 补丁被删除；当前进程继续运行原来的代码，下次冷启动运行安装包自带的版本 |
| App 调用了 `rollback()` | 补丁被删除，但不会被拉黑。设备保留已接受的最大序号，无法再次安装这个文件；请发布一个更新的补丁 |
| 用户清除了 App 数据或重装 | 补丁和本机记录一起被清除 |

## 启动诊断

`FlutterPatcher.lastBootDiagnostic` 返回最近一次冷启动时补丁的加载结果。在本次启动的首帧之前查询时，它会等到首帧之后（最多 10 秒）再返回本次的结果。

**把不健康的启动上报**到你自己的监控：

```dart
final diag = await FlutterPatcher.lastBootDiagnostic;
if (diag != null && !diag.isHealthy) {
  report('patch_boot', {                 // 换成你自己的上报方式
    'status': diag.status.name,
    'patch': diag.patchVersion,
    'crashes': diag.crashCount,
    'message': diag.message,
  });
}
```

没有补丁的启动会保留之前的 `bytecodeBootFailed`、`soBootFailed`、`droppedCircuitBreaker` 或 `droppedVersionCodeMismatch` 记录，因为它说明了补丁为什么没有运行。这条记录会保留到下一次带补丁的启动；只想上报一次时，把 `recordedAt` 和上次上报的值比较。

| `status` | 含义 | `isHealthy` |
|---|---|:---:|
| `noPatch` | 没有安装补丁 | ✅ |
| `patched` | 补丁已加载，首帧正常 | ✅ |
| `bytecodeBootFailed` | 字节码补丁启动失败，还没达到 `maxCrashCount` | ❌ |
| `soBootFailed` | SO 补丁启动失败，还没达到 `maxCrashCount` | ❌ |
| `droppedCircuitBreaker` | 补丁达到 `maxCrashCount`，已停用并拉黑 | ❌ |
| `droppedVersionCodeMismatch` | App 已升级，旧补丁被丢弃 | ❌ |
| `hookInstallFailed` | Android SO 宿主上补丁加载机制安装失败，本次运行安装包自带的版本 | ❌ |
| `unknown` | 其他情况，查看 `message` | ❌ |

其他字段：`patchVersion`（涉及的补丁序号，即封装时的 Unix 时间（秒），除非用 `publish --seq` 指定）、`patchTargetVersionCode`（补丁安装时的 App 版本号）、`appVersionCode`、`crashCount`（该补丁的失败次数）、`attemptedLoaderFields`（出现 `hookInstallFailed` 时）、`recordedAt`、`message`（给开发者看的说明）。

## 黑名单

```dart
final entries = await FlutterPatcher.blacklist;   // 查看
await FlutterPatcher.clearBlacklist();            // 清空，用于测试或确认问题已排除后
```

每个 `BlacklistEntry` 包含 `version`（补丁标识，`<宿主指纹>:<序号>:<补丁文件的 SHA-256>`）、`reason`（始终为 `BOOT_CRASH`）和 `blacklistedAt`。
