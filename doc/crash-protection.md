# 崩溃保护

本文介绍 `flutter_patcher` 如何在补丁出问题时自动回滚，并避免同一个问题补丁被反复加载。

当补丁导致启动失败，或首屏阶段出现严重 Dart 异常时，插件会在下次冷启动回到 APK 内置版本，并将问题补丁加入本地黑名单。

整个判定流程在客户端完成，不依赖服务端。  
生产环境仍建议配合灰度发布、崩溃监控和服务端紧急下架。

---

## 默认行为

默认采用 fail-fast 策略：

> 补丁加载后只要确认失败 1 次，就会被丢弃并加入本地黑名单。

下次冷启动时，应用会回到 APK 内置版本。  
插件默认不对同一个补丁进行多次重试，以避免更多用户反复遇到同样的问题。

默认配置：

```dart
await FlutterPatcher.init(
  maxCrashCount: 1,
  verifyAfter: const Duration(seconds: 5),
);
```

| 参数 | 默认值 | 说明 |
|---|---|---|
| `maxCrashCount` | `1` | 连续失败多少次后熔断补丁 |
| `verifyAfter` | `5 seconds` | 首帧后 Dart 错误钩子的守护窗口 |

`maxCrashCount` 可以调高，但通常不建议在生产环境中这样做。  
如果一个补丁已经确认会导致启动失败，重复尝试通常只会扩大影响面。

---

## 什么算作失败

插件会尽量区分“补丁导致的失败”和“用户或系统导致的正常退出”。

### 计入熔断

以下情况会被视为补丁失败，并计入熔断：

- App crash
- native crash
- ANR
- 启动或首屏阶段的严重 Dart 异常
- Dart 层异常被 framework 接住，但导致首屏白屏或不可用

### 不计入熔断

以下情况不应被视为补丁失败：

- 用户从最近任务划掉 App
- 用户按 Home 切到后台
- 用户在系统设置里强停 App
- 系统因内存压力回收进程
- 正常业务流程中的非首屏异常

不同 Android 版本的识别能力存在差异，详见 [Android 版本差异](#android-版本差异)。

---

## 启动成功窗口

补丁是否稳定，主要通过两个阶段判断。

### 1. 首帧渲染

补丁加载后，如果应用完成首帧渲染，插件会将本次启动视为初步成功，并清除启动中的熔断状态。

这样可以避免以下行为被误判为补丁失败：

- 用户首屏后按 Home
- 用户首屏后从最近任务划掉 App
- 系统在后台回收进程

### 2. `verifyAfter` 守护窗口

首帧渲染后，Dart 错误钩子会继续守护 `verifyAfter` 时间窗口，默认 5 秒。

这个窗口用于捕捉首屏阶段的 Dart 层严重异常，例如：

- 首屏点击立即触发异常
- framework 捕获了异常，但页面白屏
- 首屏关键逻辑 throw，导致应用不可用

`verifyAfter` 只在前台累计。  
窗口结束后，后续业务异常不会再归因到补丁熔断。

---

## Android 版本差异

Android 不同版本对进程退出原因的识别能力不同。

### Android 11+（API 30+）

Android 11+ 支持 `ApplicationExitInfo`，可以更准确地区分：

- 真实 crash
- native crash
- ANR
- 用户主动关闭
- 系统低内存回收

因此，Android 11+ 上的误判风险较低，首帧前后的崩溃也更容易被识别。

### Android 10 及以下

Android 10 及以下没有 `ApplicationExitInfo`。  
插件只能依赖本地启动状态来判断“上次是否在补丁加载过程中异常中断”。

这意味着：

- 首帧渲染前死亡的启动失败通常可以识别
- 首帧渲染后的 native crash / ANR 可能无法被插件归因到补丁
- `verifyAfter` 窗口内的 Dart 层异常仍然可以被错误钩子捕获

如果你的业务需要覆盖这类低版本盲区，建议结合原有崩溃监控系统，在服务端侧及时停止下发问题补丁。

---

## 黑名单

被自动回滚的补丁会以 `(version, md5)` 双键写入本地黑名单。

这意味着：

- 同一份补丁再次下发时，会直接拒绝应用
- 如果你修复 bug 后使用同样的 `version` 重新发布，只要 MD5 不同，仍然允许下载
- 手动调用 `rollback()` 不会把补丁加入黑名单
- APK 升级后，黑名单仍然保留，防止服务端误发已知问题补丁

黑名单默认使用 FIFO 策略，最多保留 50 条。超过上限后，较早的记录会被淘汰。

### 查询黑名单

```dart
final entries = await FlutterPatcher.blacklist;

for (final e in entries) {
  print('${e.version} / ${e.md5} / ${e.reason} / ${e.blacklistedAt}');
}
```

### 清空黑名单

```dart
await FlutterPatcher.clearBlacklist();
```

`clearBlacklist()` 主要用于调试，不建议在生产环境中对普通用户调用。

---

## 配置

崩溃保护相关配置在 `FlutterPatcher.init()` 中设置：

```dart
await FlutterPatcher.init(
  maxCrashCount: 1,
  verifyAfter: const Duration(seconds: 5),
);
```

### `maxCrashCount`

连续失败达到该次数后，补丁会被熔断并加入黑名单。

默认值是 `1`。  
这是推荐的生产配置。

### `verifyAfter`

首帧渲染后，Dart 错误钩子继续守护的时间窗口。

默认值是 5 秒。  
如果你的首屏初始化或首屏交互较慢，可以适当调高；如果你只希望捕捉非常早期的问题，可以调低。

---

## 监控建议

客户端崩溃保护是最后一道防线。生产环境建议同时在服务端做监控和下架。

### 1. 上报启动诊断

每次冷启动后，可以读取 `lastBootDiagnostic` 并上报：

```dart
final diag = await FlutterPatcher.lastBootDiagnostic;

if (diag != null && !diag.isHealthy) {
  analytics.report('patch_dropped', {
    'status': diag.status.name,
    'patch_version': diag.patchVersion,
    'crash_count': diag.crashCount,
    'message': diag.message,
  });
}
```

重点关注以下状态：

| 状态 | 含义 | 建议 |
|---|---|---|
| `droppedCircuitBreaker` | 补丁触发熔断 | 强告警，停止下发 |
| `droppedSignatureInvalid` | 签名校验失败 | 告警，检查补丁来源 |
| `droppedMd5Mismatch` | 本地文件与记录 MD5 不一致 | 上报并排查 |
| `droppedMetaCorrupted` | 补丁元数据损坏 | 上报并排查 |
| `hookInstallFailed` | FlutterLoader hook 失败 | 检查 Flutter 版本兼容性 |

### 2. 服务端自动下架

如果同一补丁在短时间内收到多次 `droppedCircuitBreaker`，服务端应自动停止下发该补丁。

建议将以下维度纳入判断：

- 补丁版本
- MD5
- 目标 APK `versionCode`
- ABI
- 设备 Android 版本
- App 版本
- 触发时间窗口

### 3. 灰度发布

建议按比例逐步放量：

```text
1% → 5% → 20% → 50% → 100%
```

每个阶段观察 crash 率、启动失败率和关键业务指标。  
如发现异常，应立即停止下发该补丁。

### 4. 紧急下架

紧急下架只需要从 check-update 接口中移除该补丁版本。

已经下载并触发崩溃保护的设备，会在本地回滚并拒绝再次应用同一份问题补丁。

---

## 调试

### Logcat

崩溃保护相关日志使用以下 tag：

```bash
adb logcat | grep FlutterPatcher/Guard
```

### 诊断卡片

仓库中的 `example/lib/diag_card.dart` 将诊断字段做成了可视化卡片。

真机调试时，可以直接在示例应用中查看：

- 当前补丁状态
- 上次启动诊断
- 黑名单记录
- 回滚原因

---

<details>
<summary><strong>内部实现细节</strong>（贡献者 / 好奇者参考）</summary>

## 熔断器时序

| 时机 | 行为 |
|---|---|
| `Application.attachBaseContext` | 写入 `patch_loading=true` 和当前 pid，用于下次冷启动判断 |
| Dart `FlutterPatcher.init()` | 再写一次 `patch_loading=true`，作为 native 写入失败时的兜底 |
| 首帧渲染 | 调用 `markBootSuccess`，清除 `patch_loading` 和 `crash_count`，并启动 `verifyAfter` 计时 |
| 前台累计存活 `verifyAfter` | 关闭 Dart 错误钩子的熔断窗口 |
| Dart 错误钩子触发 | 在窗口期内计入一次失败，并准备回滚 |
| 下次冷启动 `shouldLoadPatch` | 判断上次启动是否失败，并决定是否加载补丁 |
| `crash_count >= maxCrashCount` | 删除补丁文件，写入黑名单，回退 APK 内置版本 |

## Android 11+ ApplicationExitInfo 映射

Android 11+ 上，插件会根据 `ApplicationExitInfo` 判断进程退出原因。

| reason | 是否计入崩溃 |
|---|---|
| `REASON_CRASH` | 是 |
| `REASON_CRASH_NATIVE` | 是 |
| `REASON_ANR` | 是 |
| `REASON_USER_REQUESTED` | 否 |
| `REASON_USER_STOPPED` | 否 |
| `REASON_LOW_MEMORY` | 否 |
| `REASON_OTHER` | 否 |
| `REASON_SIGNALED`，例如 SIGKILL | 否 |

## Dart 层白屏兜底

补丁常见故障不一定会导致进程退出。  
例如 Dart 层 throw 被 framework 捕获，进程仍然存活，但页面已经白屏或不可用。

因此，插件会在 `init()` 时安装：

- `PlatformDispatcher.instance.onError`
- `FlutterError.onError`

在 `verifyAfter` 窗口内，任一钩子触发都会计入一次补丁失败，并在磁盘上准备回滚。

由于当前进程已经加载了补丁 `.so`，无法在不重启的情况下切回 APK 内置版本。  
实际恢复会在下一次冷启动发生。

窗口结束后，钩子仍会透明转发到原 handler，但不再向原生侧上报熔断。

</details>
