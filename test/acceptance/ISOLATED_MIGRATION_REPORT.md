# M1 基线隔离环境迁移验证

日期：2026-09-12。

## 当前结论

同一远端 Linux 上的隔离环境已完成 **归档基线恢复 → 两份补丁生成**，
全程离线；两份均为 `patch_created`，实际 tier 均为 whole。
手机重连后，两份新补丁在原宿主 APK 上的 **下载 → 重启生效 → 撤回 →
重启回退全部通过（2/2）**。本次独立环境迁移闭环已完成；这是同机隔离环境
口径的验证，不宣称物理换机或 A10 两份引擎验收完成。

该实验验证干净环境迁移，不验证独立物理主机：`independent_machine=false`。
远端未安装 Docker，实际使用 Linux mount/PID/network namespace + chroot。
这不是另一台机器或另一套内核，也不是针对恶意进程的安全沙箱测试。

## 隔离与输入

- 远端根目录：`/root/.flutter_patcher/isolation-20260912/rootfs`。
- 原构建目录 `/root/.flutter_patcher/source-regressions/20260911-225827-24eb92fe`
  在隔离环境不可访问；源码、SDK 分别置于 `/workspace/source`、
  `/toolchain/flutter`，HOME 为 `/home/acceptance`。
- `/usr` 系统工具只读挂载；`/inputs` 的归档基线、工具分发包、构建收据和
  源码清单只读挂载。仅添加标准设备文件与独立 PID namespace 的 `/proc`。
  未挂载原构建目录、Android SDK、原用户 HOME、原 pub 缓存或 Docker socket。
- 新 HOME 中先联网安装依赖并运行 doctor；这些准备步骤产生的工具缓存
  可以用于离线阶段。准备缓存中没有 `baselines`；准备项目移出隔离根目录。
  CLI 使用自己的 PUB_CACHE，因此将本环境新安装的包复制到该缓存。
- 最终离线进程只有 lo 接口，无路由。mnt、pid、net namespace ID 均与
  宿主不同；保留宿主真实 machine-id，不伪造独立主机身份。
- 最终运行断言目标基线未缓存，再通过正式 `baseline --action release
  --offline` 从 `file:///inputs/baseline-store` 恢复并校验归档、侧车、SDK
  绑定。之后运行 `patch --offline`；没有复制旧的解压基线或补丁工作目录。

构建基线的源码提交为 `bc535193707260125ab19b8b2ce799a0198a636b`，
source SHA256 为 `f5a03ef2629491d6f2a88494ee13225454d5255107760dee123b092210e8ee19`。
隔离环境在执行前逐文件核对此清单。当前 keys CLI 的后续改动不在该冻结源码中。
测试密钥为原宿主对应的公开 RFC 8032 测试密钥，不使用生产私钥。

## 结果与证据

基线指纹：`83271f6fd8fd22e6705c70c3458d5f9b2063842666dd78d1195ace53c2902731`。
引擎 build_id：`d3e60508-1354-4022-a0d4-d3259c043013`。

| 补丁 fixture | 实际 tier | 字节数 | SHA256 |
| --- | --- | ---: | --- |
| lean | whole | 2153062 | `0ead082e7337f8a7d6cefa6cd1a456c3d7eb37cb1b937cdf5f5b1615dc74c449` |
| whole | whole | 2153957 | `9f4f0f4b69641a21dfd484b17d71cbadf727251b1cba3cfc3b5fd39692cead12` |

本地证据根目录：`.dart_tool/flutter_patcher/isolation/20260912/`。
`isolation-result.json` 为 passed；`downloaded/evidence/receipts.json` 保存输入
及输出哈希，namespace、挂载和路由证据随归档保存。下载后已逐一核对两份
补丁的远端 SHA256，并核对证据归档 SHA256：
`36e776d7cae59509fdb7b3336ef91b05f12502dd88c7ec55d5fe1f9bacb34e1b`。

环境搭建过程的失败日志保留：缺少系统 alternatives、缓存目录不满足 CLI
约束、pub get 未指定 offline、工具服务 URL 改变导致离线缓存未命中、patch
离线模式不自动导入 file store、缺少 /dev/stdin，以及 CLI 的独立 PUB_CACHE。
修正后恢复仅含工具链的准备缓存，从未导入目标基线的状态完整重跑成功。
产品代码未修改。这些失败不作为成功运行的一部分拼接。

值得写入离线使用流程的限制：当前 `patch --offline` 即使给出 file store，
仍要求预先缓存基线；`baseline --action release --offline` 支持完成该导入。
本次使用现有正式入口解决，不放宽任何校验。

## 真机续跑

初次设备结果 `device/result.json` 为 failed，原因是
`device 'AF2Q025C05004551' not found`；保留不覆盖。
手机连接后从全新目录运行以下命令。corpus 仅有两份本次有效控制补丁，
用于验证下载、生效、自定义 binding、资源更新、撤回和回退；不称为 31 项矩阵。

```powershell
python test/acceptance/device.py --apk .dart_tool/flutter_patcher/regression/20260911-232309-e766a632/inputs/custom-build/release/app-release.apk --corpus .dart_tool/flutter_patcher/isolation/20260912 --out .dart_tool/flutter_patcher/isolation/20260912/device-resume-1 --serial AF2Q025C05004551 --package com.example.acceptance_app --custom-binding --cli D:/DevProjects/flutter_patcher/flutter_patcher_cli/bin/flutter_patcher.dart --dart D:/DevTools/flutter/bin/cache/dart-sdk/bin/dart.exe
```

Windows Python 若为 Store 别名，使用既有 bundled Python。
性能优化保持冻结；本次未更改手机配置、未使用 Android 模拟器、未推送或发布。

## 2026-09-12 真机续跑完成

以上续跑命令已执行，进程退出码 0。`device-resume-1/result.json` 为 passed，
两项均 passed，用例 ID 与本次两项 corpus 一致，没有拼接旧矩阵结果。
设备为 `AF2Q025C05004551`；原宿主 APK 通过已安装文件 SHA256 核验，
`apk_install=existing_sha256_verified`，本轮无需安装或重建宿主。
APK SHA256：`63bf9501a6f6c458cfeac0dc6f9d684d13cae5c30d5cb079a8b65334b963ed21`。

两项 before.revision 均为 original；after.revision/asset 分别为 lean 和
whole，after.frame 为 true，diagnostic 为 patched，crashes=0。
更新前后的 binding 均为 true。现有测试入口在撤回后重新启动并断言
revision=original，然后才把该项记为 passed，两项均完成此检查。
两份补丁哈希复核与隔离构建下载记录一致；fixture 名称不改变实际 whole tier。

最终真机结果 SHA256：
`ac8b072d0302d630a440efeafd28da23873339a4a8603b94a108b94312c9299d`。
启动采样、截图及退出记录随设备结果保留；功能通过不等于性能预算通过，
也不代替单独的字体人工审核、体积门槛或 A10。
