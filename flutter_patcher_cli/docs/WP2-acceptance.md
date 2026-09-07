# WP-2 本地验收 · 2026-09-08

WP-2 工具链准备实现完成，待用户审核。代码位于 `flutter_patcher` 本地 `codex/wp2` 分支；未推送代码库分支、tag 或 Release。插件根目录的运行时、原生代码和 `pubspec.yaml` 未修改，原有文件仅 `.pubignore` 增加 CLI 排除项。

## artifacts Release

用户本次明确批准使用现有工作流构建精简 Release。已创建并发布 [flutter-3.47.2](https://github.com/xuelinger2333/flutter_patcher_artifacts/releases/tag/flutter-3.47.2)。没有修改 artifacts 工作流源码；构建来源 `8518c2dfd962139c2283c9244e4ae09cf4143d22`。

- [引擎 workflow 34149439718](https://github.com/xuelinger2333/flutter_patcher_artifacts/actions/runs/34149439718)：成功。
- [工具 workflow 34149442188](https://github.com/xuelinger2333/flutter_patcher_artifacts/actions/runs/34149442188)：成功。
- 引擎 build_id：`d3e60508-1354-4022-a0d4-d3259c043013`。
- Flutter `3.47.2`，Dart `3.13.2`，framework `d3b14c876900e553bc736ca19295fc09e3853e8e`，engine `a804b261645ef8c13eb3d5c44a5c2fb0340c5539`。

| 附件 | 实测字节数 |
|---|---:|
| libflutter-arm64_v8a-release.jar | 11,908,360 |
| gen_snapshot-linux-x64 | 6,295,056 |
| flutter_patcher_tools-3.47.2.dill | 37,039,112 |
| flutter_embedding_release.jar | 1,584,072 |
| engine.manifest.json | 1,771 |
| tools.manifest.json | 646 |

共六个附件，无 YAML 或第二个工具 dill。CLI 冷启动从公开 Release 重新下载、解析 manifest 并校验实际文件。GitHub digest 记录见 [release.json](evidence/release.json)，下载的两份 manifest 见 [engine.manifest.json](evidence/engine.manifest.json) 和 [tools.manifest.json](evidence/tools.manifest.json)。

## 测试结果

| 检查 | 实测结果 |
|---|---|
| Windows / Dart 3.10.7 analyze | No issues found |
| Windows 测试 | 36 项通过 |
| Linux x64 / Dart 3.13.2 analyze | No issues found |
| Linux 测试 | 35 项通过，1 项非 Linux 主机测试按条件跳过 |
| 最终代码、空缓存、真实 Release doctor | 退出 0，76,152 ms，下载器请求 13 次（包含重定向） |
| `unshare -n` 网络隔离、`--offline` | 退出 0，10,288 ms，下载器请求 0 次 |
| 显式提供密钥/基线/侧车存在性样本 | 退出 0，4,806 ms，下载器请求 0 次 |
| 显式提供缺失密钥 | 退出 1，KEYS_MISSING，4,665 ms |
| path 全局安装及安装后 `--help` | 成功 |
| 所选 SDK 前后文件 SHA-256 清单 | 排除 `.git`，17,572 个文件，完全一致 |

离线复验与冷启动通过同一缓存锁协调，所记时长包含可能的锁等待，不是性能基准。`network_requests` 只计 CLI 下载器请求，不统计 git/precache/pub 子进程；离线无网络能力由 Linux `unshare -n` 另行保证。

冷启动实际完成：支持版本解析、四个二进制文件下载校验、精确 framework 副本建立、stock precache、gen_snapshot 替换、Maven 镜像准备、下载 dill 的入口与 bytecode 冒烟、两份 YAML 生成、最小 arm64 AOT ELF 编译。

单元测试覆盖严格 manifest 约束（含重复 JSON 键）、独立 builder commit、Dart 不匹配、哈希错误、下载中断、不可提交的半缓存、缓存隔离修复、支持表更新、YAML 源码/工具变更及损坏重生成、SDK 缓存过期拒绝、命令错误和 APK 内部 SO 校验。

原始简要证据：

- [冷启动 JSON](evidence/cold-final.json)、[离线 JSON](evidence/offline-final.json)。
- [上下文存在性检查 JSON](evidence/context-present.json)、[缺失密钥 JSON](evidence/context-missing.json)。
- [Windows 测试输出](evidence/tests-windows.txt)、[Linux 测试输出](evidence/tests-linux.txt)、[安装入口输出](evidence/installed-help.txt)。
- [证据收据](evidence/receipt.json)：被测试源码 SHA-256、SDK 前后清单 SHA-256、文件数及网络隔离方法。完整 SDK 清单留在服务器证据目录，未提交大型文件。

服务器验收源码：`/root/.flutter_patcher/wp2-development/flutter_patcher_cli`；原始证据：`/root/.flutter_patcher/wp2-development/evidence`；受管验收缓存：`/root/.flutter_patcher/wp2-acceptance-final`。这些是开发/验收路径，不是 CLI 的固定运行要求。

复验命令（已准备好缓存和 CLI 包依赖）：

```bash
cd /root/.flutter_patcher/wp2-development/flutter_patcher_cli
export PUB_CACHE=/root/.flutter_patcher/wp2-development/pub-cache
unshare -n /root/.flutter_patcher/artifacts-builder/cache/flutter-3.47.2/bin/cache/dart-sdk/bin/dart \
  bin/flutter_patcher.dart doctor \
  --flutter-sdk /root/.flutter_patcher/artifacts-builder/cache/flutter-3.47.2 \
  --cache-dir /root/.flutter_patcher/wp2-acceptance-final --offline --json
```

## 尚未宣称通过的部分

- 密钥和基线的存在性验收使用明确标注的测试样本，不是有效签名密钥或 WP-4 完整基线，不代表密码学/内容绑定验证成功。
- APK 哈希逻辑由合成 ZIP 测试覆盖；本次没有构建并验收真实应用 APK，没有真机运行、补丁更新或完整 A1/A10。
- Maven 镜像已准备，WP-5 仍需实际接入 Gradle 并验证引擎注入；embedding 是否可从 Google 仓库解析仍待该工作包。
- build、patch、publish、keys 返回 COMMAND_NOT_IMPLEMENTED；没有推进其他工作包。
- JSON 的 `toolchain_ready` 是 WP-2 工具链就绪，`all_checks_complete` 保持 false；未提供的上下文和设备检查明确标记 not_run。

本地忽略的 `plan/SPEC_M1.md` 已恢复已审核 rev3 架构并补充 WP-2 实施/验收约定；原工作副本有本地备份，不随 Git 提交。
