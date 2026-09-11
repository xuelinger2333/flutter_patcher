# M1 收口：custom 矩阵与 keys init

日期：2026-09-11。当前为执行中的记录，custom 完整结果尚未产生。

## 本轮范围

按用户决定停止性能优化，保留 native 字节直传后的实现，不修改 entry SHA、
CRC、调度或预算。standard 最近一次为 31/31、仪器 4/4；lean 平均 65.3 ms，
whole 205.9 ms，后者十次均未满足 200 ms。这份历史性能结果不改写为通过。
CRC/entry 一致性检查是否调整，与 FFI 一起进入 M1.5 设计。

本轮只收口 custom 的同一 31 项故障矩阵和 CLI 正式密钥初始化。
不发布、不推送、不使用 Android 模拟器、不更改手机设置。

## keys init

实现提交：`a03e715`。命令：`flutter_patcher keys init [--out NEW_DIRECTORY]`。
Linux x64/WSL2，使用 PATH 中支持 Ed25519 的 OpenSSL，不需要 Flutter SDK
或网络。默认 `~/.flutter_patcher/keys`，输出 raw32 seed/public 的 Base64
文件，直接供现有 build/patch 使用。目录 700、私钥 600；秘密不进入命令
参数或日志，也不生成临时私钥 DER 文件。输出元数据只有路径、格式和公钥
指纹。已有目录拒绝覆盖，符号链接拒绝，并发初始化恰好一个成功。

Windows 的 CLI 帮助/用法/平台拒绝测试 6/6；Linux CLI 全套 87 passed、
0 failed、2 skipped。跳过的是未启用的真实 AWS CLI + 隔离 S3 集成测试，
以及 Linux 不适用的 unsupported-host 测试。新增 keys 测试没有跳过。

测试覆盖：生成两对不同密钥、私钥/目录权限、不泄露私钥、已有密钥不变、
并发竞争、符号链接、缺失 OpenSSL、默认 HOME 输出，以及现有 bootstrap
接受公钥、签名打包器使用生成的 seed 完成实际 OpenSSL Ed25519 签名/验签。
模块内容为标明的合成签名测试输入；不把这项 CLI 契约测试描述为新 APK
使用随机生产密钥的真机测试。测试生成的私钥仅在独立临时目录中使用。

首轮全套测试因隔离副本缺少 `.github/workflows/test.yml` 而失败，keys
用例均通过；补齐这一测试输入后全套重新运行通过。两份日志均保留。
数据：`.dart_tool/flutter_patcher/keys-validation/result-final.json`，
`tests.log`、`tests-2.log`、`source.json`。最终记录保存源码/日志与补充
workflow 文件的哈希。使用说明见 CLI README 的“初始化正式签名密钥”。

## custom 重建

运行目录：`.dart_tool/flutter_patcher/regression/20260911-225827-24eb92fe/`。
冻结提交：`bc53519`；源码 SHA256：
`f5a03ef2629491d6f2a88494ee13225454d5255107760dee123b092210e8ee19`。
运行时与此前 standard 相同。keys CLI 改动在独立测试副本验证，不修改
运行时或已冻结的 custom 构建输入。

配置基于现有 regression-config.example.json，仅 binding 改为 custom；
仍使用同一个 rebuild_regression / run_matrix 入口，生成新的匹配宿主、
补丁和 corpus，不使用旧启动协议的 custom 产物。矩阵将显式检查原应用
和补丁均保留自定义 binding，并按 corpus 声明的实际 tier 记录结果；
`valid-lean` 的文件名不代表 custom 一定具有 lean 控制补丁。
