# WP-3 源码实现与验收记录

2026-09-08。两个仓库均在本地 `codex/wp3` 分支实施，尚未推送。插件运行时、原生代码和插件 pubspec 不变；引擎代码、构建脚本和已发布 Release 不变。

## 实现

- artifacts：提取器、规范化接口集合、常用控件/平台策略、导出声明范围内的提示解析、SDK trimmer；四个新命令全部接入单工具入口。
- CLI：`interface` 编排、有限轮次校验、原子输出、失败诊断、旧工具能力检查、在线工具刷新及 SDK 索引缓存检查。没有实现 build/patch/publish、基线归档或运行时加载。
- 精简档实际裁剪宿主和平台 kernel，并通过 `--import-dill` 验证；整程序档使用完整平台接口和限定动态调用策略，不导入宿主框架 kernel。
- 只有 `Procedure` getter/setter 加前缀；常量反查保留所有公开别名；私有成员/类容器过滤；枚举保留类级 callable；裁剪接口不重复 YAML 键。
- 名字解析只暴露导入库及其实际导出声明，遵循 show/hide；不会因 material 导出 Matrix4 就把 vector_math 的 Colors 纳入候选，也不会把未导入 dart:ffi 的 Size 混入 dart:ui.Size。剩余歧义直接失败。

## 实测结果

| 验证 | 结果 |
|---|---|
| CLI Windows analyze / Dart 3.10.7 | No issues found |
| CLI Windows tests | 44 项通过 |
| CLI Linux analyze / Dart 3.13.2 | No issues found |
| CLI Linux tests | 43 项通过，1 项非 Linux 主机用例按平台跳过 |
| tools 新源码 analyze / Dart 3.13.2 | No issues found |
| tools 接口结构用例 | 9 组通过 |
| 既有 detect_shape 结构回归 | 9 组通过 |
| 工具流水线 Python 契约测试 | 23 项通过 |
| 实际 Flutter kernel + 工具源码：精简档 | 第 2 轮收敛；字节码 133,977 字节 |
| 实际 Flutter kernel + 工具源码：整程序档 | 第 1 轮通过；字节码 8,832,525 字节 |
| CLI InterfacePipeline + 实际工具源码 | 精简档第 2 轮收敛，完成输出提交 |
| 修改后的 CLI 执行断网 doctor | toolchain_ready；下载请求 0 |
| stock SDK 文件清单对比 | 排除 .git，17,572 个文件 SHA-256 与原清单一致 |

真实样本使用 Flutter 3.47.2 / Dart 3.13.2，包含 Container、Row、Text、枚举、EdgeInsets 和 Colors.transparent；精简档第一轮真实编译器提示触发常量成员补全。每次合并以同样输入重复执行，并比较两份接口的字节一致性。

CLI 测试覆盖收敛、无进展、最多五轮、已有输出保护、旧工具拒绝、两档编译参数差异、刷新失败保留旧缓存、刷新不动引擎、离线刷新拒绝，以及 SDK 索引损坏后重建。

证据：

- [工具源码两档验证](wp3-evidence/tool-source-integration.json)
- [CLI 实际编排验证](wp3-evidence/pipeline-source.json)
- [Windows 测试](wp3-evidence/tests-windows.txt)、[Linux 测试](wp3-evidence/tests-linux.txt)、[工具结构测试](wp3-evidence/tool-tests.txt)
- [doctor 回归](wp3-evidence/doctor-regression.json)、[源码及 SDK 收据](wp3-evidence/receipt.json)

服务器源码验证目录为 `/root/.flutter_patcher/wp3-development/`，与正式仓库及已审核 WP-2 安装目录分开。临时探针、裁剪产物与日志留在该目录，未提交大型二进制。

## 验收边界与后续步骤

**源码实现和上述验证完成，不等于新版 CI dill/Release 验收完成。** 本次没有在本地编译或发布工具 dill；集成验证直接执行开发源码。`pipeline-source.json` 中的 `tool_sha256` 是源码入口文件哈希，不是发布 dill 哈希，完整运行源码哈希另见收据。

`build_tools.py` 已接入接口结构测试，并让 `interface_smoke.py` 对 CI 编出的单 dill 跑两档真实验证；原双轮编译及 A11 比较保留。该新版 CI 尚未运行，快照构建大小、构建时长、A11 结果为 TBD。

按照先审核后推送的约定，下一步是审核两个本地分支后，允许推送测试分支并运行 `build-tools`（publish=false）。当前上传步骤仍受 publish 门控，CI 检查不会自动覆盖 Release。公开 Flutter 3.47.2 工具当前仍是 WP-2 版本，因此普通用户使用现有 Release 执行 interface 会收到 TOOLS_VERSION_UNSUPPORTED。

发布新的工具附件另行审核。上线后用户通过 `doctor --refresh-tools` 更新；不要求用户重编工具，不需要重建引擎，也不增加 Release YAML 文件。

没有运行宿主 APK 构建、真机补丁加载或 A1 闭环。生成报告明确标记 `host_build_verified=false`、`device_verified=false`；这些验证产物不得当成可直接发布的补丁。

本地忽略的 `plan/SPEC_M1.md` 已补充四个工具入口、CLI interface、两档校验路径、缓存刷新与本阶段验收边界；修订前副本保留在 `.dart_tool/flutter_patcher/wp3/SPEC-before-WP3.md`。
