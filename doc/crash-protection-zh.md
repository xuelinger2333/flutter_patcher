# 崩溃保护

[English](crash-protection.md) | **简体中文**

一个补丁可能通过了所有构建期检查，却在某些设备上启动即崩溃。本文说明插件如何发现这种情况、如何自动恢复，以及你如何观察它。

无需额外配置即可生效；在 `main()` 中调用 [`FlutterPatcher.init()`](api-reference-zh.md#init) 可以设置 `maxCrashCount`，并在首帧之后继续统计 Dart 异常。

## 一次带补丁的启动

```text
冷启动，有已安装的补丁
  → 记录"正在尝试启动补丁"
  → 加载补丁，运行 App
  → 首帧绘制完成 → 本次启动成功，清零失败计数
```

如果在首帧之前进程就结束了，或者 Dart 代码抛出了未捕获的异常，这次启动就记为**失败**。

## 什么算启动失败

| 情况 | 判定 |
|---|---|
| 首帧之前抛出 Dart 未捕获异常 | 失败 |
| 首帧之后 `verifyAfter`（默认 5 秒，只计 App 在前台的时间）内抛出 Dart 未捕获异常 | 失败 |
| 首帧之前进程崩溃、ANR 或初始化失败 | 失败，下次启动时判定 |
| 首帧之前用户主动划掉 App、系统回收内存 | Android 11 及以上不算失败；更低版本无法区分，会算作失败 |
| iOS 上首帧之前 App 被切到后台 | 不算失败 |
| 首帧之后、补丁进程仍在运行时发生崩溃或 ANR | Android 11 及以上：失败，下次启动时判定。Android 10 及以下和 iOS：检测不到，请依靠你的崩溃监控 |

Android 11 及以上通过系统的 `ApplicationExitInfo` 获取补丁进程的结束原因，只有崩溃、原生崩溃、ANR 和初始化失败才计数，不论它们发生在这个进程的什么时候。

## 失败之后

每个补丁有自己的失败计数。达到 `maxCrashCount`（默认 1）时**熔断**：

1. 补丁被停用，下次冷启动运行安装包自带的版本；
2. 补丁被加入本机**黑名单**，之后 `applyPatch` 再遇到同一个补丁会返回 `blacklisted`；
3. 记录启动诊断 `droppedCircuitBreaker`。

未达到阈值时，下次启动仍会尝试这个补丁，诊断为 `bytecodeBootFailed`（SO 宿主为 `soBootFailed`）。

一个补丁的代码无法加载（例如文件损坏、授权已被撤回）时，同样会被计为一次失败。SO 宿主上，如果补丁的 `libapp.so` 已经加载、其余部分却加载失败，补丁会被立即拉黑，不受 `maxCrashCount` 影响。

把 `maxCrashCount` 调大可以容忍偶发的失败，但有问题的补丁也会让用户多经历几次失败的启动。一般保持默认值。

## 其他会让补丁失效的情况

| 情况 | 结果 |
|---|---|
| 用户把 App 升级到新版本 | 旧版本的补丁自动失效，诊断为 `droppedVersionCodeMismatch` |
| 你发布了覆盖该补丁序号的撤回 | 设备在下次检查更新并应用撤回后删除补丁，见[生产部署](production-playbook-zh.md#撤回补丁) |
| App 调用了 `rollback()` | 补丁被删除，但不会被拉黑。设备已经接受过它的序号，所以无法再次安装这个补丁；请发布一个序号更大的补丁 |
| 用户清除了 App 数据或重装 | 补丁和本机记录一起被清除 |

## 启动诊断

`FlutterPatcher.lastBootDiagnostic` 返回最近一次冷启动时补丁的加载结果。如果在本次启动的首帧之前查询，它会等到首帧之后（最多 10 秒）再返回本次的结果。

没有补丁的启动会保留之前的 `bytecodeBootFailed`、`soBootFailed`、`droppedCircuitBreaker` 或 `droppedVersionCodeMismatch` 记录，因为它说明了补丁为什么没有运行。所以这条记录会一直保留到下一次带补丁的启动；如果只想上报一次，可以把 `recordedAt` 和上次上报的值比较。

```dart
final diag = await FlutterPatcher.lastBootDiagnostic;
if (diag != null && !diag.isHealthy) {
  // 换成你自己的上报方式
  report('patch_boot', {
    'status': diag.status.name,
    'patch': diag.patchVersion,
    'crashes': diag.crashCount,
    'message': diag.message,
  });
}
```

**`status` 的取值**

| 值 | 含义 | `isHealthy` |
|---|---|:---:|
| `noPatch` | 没有安装补丁 | ✅ |
| `patched` | 补丁已加载，首帧正常 | ✅ |
| `bytecodeBootFailed` | 字节码补丁启动失败，还没达到熔断阈值 | ❌ |
| `soBootFailed` | SO 补丁启动失败，还没达到熔断阈值 | ❌ |
| `droppedCircuitBreaker` | 补丁达到失败阈值，已停用并拉黑 | ❌ |
| `droppedVersionCodeMismatch` | App 已升级，旧补丁被丢弃 | ❌ |
| `hookInstallFailed` | Android SO 宿主上补丁加载机制安装失败，本次运行安装包自带的版本 | ❌ |
| `unknown` | 其他情况，查看 `message` | ❌ |


**其他字段**：`patchVersion`（涉及的补丁序号）、`patchTargetVersionCode`（补丁安装时的 App 版本号）、`appVersionCode`、`crashCount`（该补丁的失败次数）、`attemptedLoaderFields`（出现 `hookInstallFailed` 时）、`recordedAt`、`message`（给开发者看的说明）。

## 黑名单

```dart
final entries = await FlutterPatcher.blacklist;   // 查看
await FlutterPatcher.clearBlacklist();            // 清空
```

每个 `BlacklistEntry` 包含 `version`（补丁标识，`<指纹>:<序号>:<sha256>`）、`reason`（始终为 `BOOT_CRASH`）和 `blacklistedAt`。

黑名单只在本机生效，补丁本身仍在你的发布存储中，其他设备照样可以下载。所以一旦在监控中看到 `droppedCircuitBreaker`，应该尽快[撤回](production-playbook-zh.md#撤回补丁)这个补丁，或者发布修复后的新补丁。
