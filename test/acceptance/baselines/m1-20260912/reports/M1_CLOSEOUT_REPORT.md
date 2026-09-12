# M1 收口：custom 矩阵与 keys init

日期：2026-09-11。keys init 已完成；custom 真机完整矩阵 31/31、仪器测试
4/4 通过。本轮两个收口条件均已完成；不据此宣称整体发布条件全部满足，
此前 whole 性能预算未达标的事实仍保留。

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

本轮实际产物：APK 24,952,882 bytes；native JVM 33/33，零失败/错误/跳过；
corpus 31 项。`valid-lean` 与 `valid-whole` 的实际 tier **均为 whole**，
分别保留测试 revision 名称 lean/whole，不宣称 custom lean 能力已验收。
下载归档 SHA256 与远端一致：
`d294cb707bcc2e8fe7e3291dcf0195064751724e7328c10c2ae6ac2560169e34`。

首次运行进入 instrumentation 安装阶段时 ADB 报
`device 'AF2Q025C05004551' not found`，随后 `adb devices` 为空。
顶层 `result.json` 保留 failed；`inputs/build-result.json` 为 passed。
该失败运行没有 custom 仪器测试或真机矩阵通过记录，不把构建成功算作真机验收。

手机重新连接后，以相同冻结产物开始新的结果目录：

```powershell
python test/acceptance/rebuild_regression.py --config .dart_tool/flutter_patcher/regression/20260911-225827-24eb92fe/config.json --resume-built .dart_tool/flutter_patcher/regression/20260911-225827-24eb92fe
```

Windows 的 Python 若为 Store 别名，使用既有 bundled Python 路径。此入口
会先核对归档及源码身份，再跑仪器 4 项和完整矩阵；不重建、不覆盖失败记录。

## custom 真机最终结果

手机重新连接后，以上命令已完成一次完整运行，进程退出码 0。
新目录：`.dart_tool/flutter_patcher/regression/20260911-232309-e766a632/`。
顶层 `result.json` 为 `passed` / `complete`，仪器测试 4/4；
`matrix/result.json` 为 passed，31/31 全部 passed，无跳过、无拼接。
逐项核对 ID 与顺序均与 `inputs/custom-corpus/corpus.json` 一致。
原始设备断开失败目录保留不变。

设备为 HONOR MEY-AN00、Android 16 / API 36、arm64-v8a，序列号
`AF2Q025C05004551`。测试 APK SHA256：
`63bf9501a6f6c458cfeac0dc6f9d684d13cae5c30d5cb079a8b65334b963ed21`。
31 项的 before.binding 均为 true；两个有效控制的 after.binding 也均为
true，revision/asset 分别更新为 lean 和 whole，并有 patched 首帧记录。
两个控制实际 tier 均为 whole，不把 fixture 名称当作 custom lean 验收。
故障项覆盖拒绝、回退与隔离，包含 main 抛异常及卡住后的恢复。

对冻结 source.json 中全部文件重新核对，差异仅为 CLI README、CLI 命令
分派与对应测试；运行时、已有验收脚本均匹配冻结源码。新增 keys 文件由
前述独立 CLI 套件验证，不宣称整个当前仓库与冻结构建完全相同。

最终证据 SHA256：

| 文件（相对新运行目录） | SHA256 |
| --- | --- |
| result.json | `0b180c5f720d9eb4694d868f56b17ee5bf4046478a1fa1a2b9c3db3b97ed5038` |
| matrix/result.json | `856a83ebcf34cbb665ca1dcaa79880793351eb85d3c572681a6a309b532f916b` |
| instrumentation.txt | `7ad45bbbe4cee8473812091677ba7a1ca52bd50e2b1fbc6c9aa670aaef6e3157` |

矩阵通过指功能/故障断言通过；附带的 timing 文件与预算标记原样保留，
不将功能通过等同于 whole 性能达标。本轮未修改性能代码或手机配置，
未使用模拟器，未推送或发布。
