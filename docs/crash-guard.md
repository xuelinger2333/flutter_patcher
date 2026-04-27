# 崩溃保护机制

> 这是用 flutter_patcher 最需要理解的部分。本文档描述补丁加载失败时的自动回滚流程、熔断判定规则、黑名单策略，以及配套的诊断接口。

---

## 设计目标

- **对用户的影响最小化：** 补丁有问题时，用户最多看到一次白屏（app 闪退），下次打开 app 自动恢复正常。不会出现反复崩溃、需要卸载重装的情况。
- **不放大故障：** 失败的补丁绝对不再加载，即使下次还能下到同一份。
- **不误伤用户操作：** 用户从最近任务划掉、按 Home、被系统 OOM 不算补丁的命数。
- **不依赖远端：** 整套熔断+回滚链路在客户端本地闭环，服务端宕机也能正常回退。

---

## 默认行为：fail-fast

补丁加载后启动失败 **1 次** 即丢弃 + 入本地黑名单。不给"再试一次"的机会，因为生产环境里坏补丁不会第二次变好。

这是默认值。可以通过 `maxCrashCount` 调高阈值，但通常不建议——多次重试只会让更多用户看到白屏。

```dart
await FlutterPatcher.init(maxCrashCount: 1); // 默认
```

---

## verified 三层判定

补丁加载后必须满足 **三个条件** 才算 verified：

1. **反射注入成功**——`FlutterLoader` 替换为补丁版本。
2. **首帧渲染完成**——Flutter 走完 `WidgetsBinding.instance.addPostFrameCallback` 第一次回调。
3. **前台存活 N 秒不 crash**——只在 `AppLifecycleState.resumed` 状态下累计计时，默认 5 秒。

第三条是关键：只有用户真的看到画面、停留足够时间，才能确认这份补丁是健康的。用户启动后立刻按 Home 切后台，计时暂停，不会被错误地标记为 verified。

```dart
await FlutterPatcher.init(verifyAfter: const Duration(seconds: 5)); // 默认
```

verified 之后，本次启动就不再受熔断器干预。

---

## 真崩溃 vs 用户主动关闭

熔断器要回答的核心问题是：**上次启动到底是不是因为补丁挂了？**

### Android 11+（API 30+）

调用 [`ActivityManager.getHistoricalProcessExitReasons`](https://developer.android.com/reference/android/app/ActivityManager#getHistoricalProcessExitReasons(java.lang.String,int,int)) 精确区分进程退出原因：

| ApplicationExitInfo.reason | 是否计入崩溃 |
|---|---|
| `REASON_CRASH` / `REASON_CRASH_NATIVE` | ✅ 真崩溃，计一次 |
| `REASON_ANR` | ✅ ANR 也算补丁问题 |
| `REASON_USER_REQUESTED` | ❌ 用户从最近任务划掉 |
| `REASON_USER_STOPPED` | ❌ 用户在设置里强停 |
| `REASON_LOW_MEMORY` / `REASON_OTHER` | ❌ 系统行为，不归补丁 |
| `REASON_SIGNALED` (SIGKILL) | ❌ 系统杀进程 |

### Android 10 及以下（API < 30）

没有 `getHistoricalProcessExitReasons` API（覆盖率约 5–10% 的存量设备），走朴素策略：

- 熔断器在 `attachBaseContext` 写入 `patch_loading=true`
- 首帧渲染 + 前台存活 N 秒后清零
- 下次冷启动发现 `patch_loading==true` 直接计一次失败

这个策略会误伤极少数用户（启动过程中主动滑掉的），但对低版本占比已经很低的现状是可接受的工程取舍。

---

## Dart 层白屏兜底

补丁最常见的故障形态 **不是进程崩溃**，而是 Dart 层 throw 被 framework 接住、进程不死但白屏。这种情况下 `ApplicationExitInfo` 看不到任何异常退出。

插件在 **未 verified 窗口内** 安装两个错误钩子：

- `PlatformDispatcher.instance.onError`——拦截未捕获的异步错误
- `FlutterError.onError`——拦截 widget tree 异常

任意一个钩子触发，等同于一次崩溃，立即写入 `patch_loading=false` + `crash_count++`，并同步触发回滚（不等下次冷启动）。

verified 之后，这两个钩子恢复成原 handler（用户在 `main.dart` 里设置的那个）。**业务代码本身的异常不会影响补丁。**

---

## 黑名单

被自动回滚的补丁以 `(version, md5)` **双键** 写入本地黑名单：

- 下次拉到同一份补丁（version + md5 都一样）→ 直接拒绝，不浪费流量
- 开发者修了 bug 后用同样 version 重发（md5 必然不同）→ 允许下载
- FIFO 上限 50 条，超出按入队顺序淘汰
- 跨 APK 升级保留（即使升级了基准 APK，已知的坏补丁仍然被屏蔽）

```dart
// 查看黑名单
final entries = await FlutterPatcher.blacklist;

// 清空黑名单（仅调试用，生产环境不要调用）
await FlutterPatcher.clearBlacklist();
```

**手动调用 `FlutterPatcher.rollback()` 不会入黑名单**——这是用户主动行为，不是补丁本身有问题。

---

## 熔断器时序

| 时机 | 行为 |
|---|---|
| `Application.attachBaseContext` | 写入 `patch_loading=true` + pid（同步 `commit`，不能用 `apply`） |
| Dart `FlutterPatcher.init()` | 再写一次 `patch_loading=true`（兜底，防止反射阶段就挂了） |
| 首帧渲染 | 启动前台存活计时器 |
| 前台累计存活 N 秒 | `patch_loading=false`，`crash_count=0`，卸载错误钩子 |
| Dart 错误钩子触发（未 verified 期间） | `crash_count++`，立即触发回滚 |
| 下次冷启动发现 `patch_loading==true` | API 30+ 查 `ApplicationExitInfo` 区分；API < 30 直接计一次失败 |
| `crash_count >= maxCrashCount` | 删除补丁文件 + 入黑名单，回退 APK 内置版本 |

Logcat tag `FlutterPatcher/Guard` 输出所有崩溃判定日志，调试时 `adb logcat | grep FlutterPatcher/Guard`。

---

## 诊断与可观测性

补丁装上之后，冷启动阶段仍可能因 versionCode 不匹配、签名失败、熔断触发等被原生侧丢弃。这些事件通过 `lastBootDiagnostic` 结构化暴露到 Dart：

```dart
final diag = await FlutterPatcher.lastBootDiagnostic;
if (diag != null && !diag.isHealthy) {
  analytics.report('patch_dropped', {
    'status': diag.status.name,
    'patch_version': diag.patchVersion,
    'crash_count': diag.crashCount,
  });
}
```

| status | 含义 | 处理建议 |
|---|---|---|
| `patched` | 补丁加载成功 | 无需处理 |
| `noPatch` | 无补丁，使用 APK 内置版本 | 无需处理 |
| `droppedVersionCodeMismatch` | APK 升级后旧补丁失效 | 正常流程，重新拉取最新补丁 |
| `droppedCircuitBreaker` | 连续启动失败达熔断阈值 | **强告警**：补丁有 bug，通知服务端下架 |
| `droppedSignatureInvalid` | 签名校验失败 | **强告警**：可能被篡改 |
| `droppedMd5Mismatch` | 本地文件 MD5 不一致 | 上报：磁盘损坏或篡改 |
| `droppedMetaCorrupted` | 元数据损坏 | 上报 |
| `hookInstallFailed` | 反射替换失败 | 跟进 Flutter 版本适配 |

`example/lib/diag_card.dart` 将全套字段做成了一张可视化卡片，真机调试时直接看屏幕即可。

---

## 错误处理（applyPatch 阶段）

`applyPatch` / `applyPatchBytes` 返回 `PatchApplyResult`：

```dart
final r = await FlutterPatcher.applyPatch(info);
if (!r.ok) {
  switch (r.error!) {
    case PatchApplyError.network:
    case PatchApplyError.ioError:
      // 可重试（建议指数退避，最多 3 次）
      break;
    case PatchApplyError.blacklisted:
      // 该补丁曾导致崩溃，通知服务端下架，不重试
      break;
    case PatchApplyError.signatureInvalid:
      // 可能被篡改，上报安全事件，不重试
      reportSecurityEvent(r.message);
      break;
    case PatchApplyError.md5Mismatch:
      // CDN 脏数据或服务端 MD5 错算，检查后重试
      break;
    default:
      log.warning('patch: ${r.error?.name} / ${r.message}');
  }
}
```

完整错误码：`invalidArgs`、`blacklisted`、`bsdiffDisabled`、`network`、`md5Mismatch`、`signatureInvalid`、`bsdiffApplyFailed`、`targetMd5Mismatch`、`ioError`、`unknown`。

> 同版本补丁重复调用 `applyPatch` 幂等返回 `ok=true`。versionCode 不匹配在下次冷启动检测，不在此处报错。

---

## 推荐的服务端联动

客户端崩溃保护是最后一道防线。生产环境建议同时在服务端做：

- 接收客户端 `droppedCircuitBreaker` 上报，同一补丁短时间收到 N 次回滚事件后 **自动停止下发**
- 灰度发布：先放 1% → 5% → 20% → 100%，配合监控指标观察 crash 率
- 紧急下架开关：从 check-update 接口的返回中移除该版本，已安装的用户不受影响直到下次冷启动拉新配置
