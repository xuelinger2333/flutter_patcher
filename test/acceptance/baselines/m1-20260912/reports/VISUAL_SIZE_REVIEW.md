# 字体与空应用体积：待用户审核

日期：2026-09-12。字体审核及体积阈值均未批准，本报告不标记验收通过。

后续进展：用户已接受当前体积增量，并要求保留 .so 可选模式；具体 gate
阈值仍未写入。用户指出原截图仅显示图标变化后，已补真实文字字体替换用例，
见 TEXT_FONT_REPORT.md：四项自动闭环通过，新的三阶段截图等待视觉确认。
以下原截图与原阈值建议作为历史审核材料保留。

## 字体材料

本地审核页：`.dart_tool/flutter_patcher/visual-size-review-20260912/font-review.html`。
六张真机原图来自 standard 最终矩阵及 custom 隔离迁移闭环，分别展示原版、
控制一、控制二；原路径和 SHA256 记录在同目录 font-review.json。
standard 的两份补丁分别为 lean/whole；custom 两份均为 whole。
检查 original/lean/whole 文本、房屋图标及 whole 新增的爱心字形。

限制：验收页未避开状态栏，图标局部有系统信息重叠；覆盖 MaterialIcons，
不代表任意自定义字体或中文字库已验收。回退已有自动断言，但缺少独立回退
截图。本次启动应用并补拍的命令被自动审批以 blocked by policy 拒绝，
未返回具体原因，未重试；改用已存在原图。用户可接受有限覆盖，或要求补拍，
不能在确认之前标记字体通过。

## 空应用实测

远端 `/root/.flutter_patcher/empty-review-20260912/`，现有 empty_size.py 入口。
同一项目仅运行 SizedBox.shrink，无 HTTP 验收控制器；Flutter 3.47.2，
Android arm64 release。两份均声明插件依赖，对照衡量启用正式 bootstrap
的增量；APK 差值不等同于从无插件开始接入的全部成本。

使用冻结源码 bc53519，source SHA256
`f5a03ef2629491d6f2a88494ee13225454d5255107760dee123b092210e8ee19`。
构建后复核当前 lib/、android/ 与冻结清单一致；keys CLI 后续改动不在此构建中。

| 指标 | 普通版本（bytes） | 正式引导版本（bytes） | 增量 |
| --- | ---: | ---: | ---: |
| libapp.so | 1,508,232 | 10,617,736 | 9,109,504（8.69 MiB） |
| APK | 13,715,809 | 22,985,657 | 9,269,848（8.84 MiB） |

ZIP 内容对比主要差异是 libapp.so 增加 9,109,504 bytes 和 libflutter.so
增加 160,344 bytes。其余 APK 容器开销另计。这里记录组成，不把尚未分析的
libapp 增量直接归因于单个函数或优化空间。

两个构建成功，正式引导版本 baseline_archived；size.json 的
threshold_bytes=null、status=not_run，尚未运行已批准阈值的 gate。
本地证据在 `.dart_tool/flutter_patcher/visual-size-review-20260912/size/`，
包括 build.json、源码清单、APK/entry 哈希、锁文件、源码及构建日志。
下载归档 SHA256：`34d6105c54c8b9a88d90c9eeefd95ec9c6b1a2e4e14f3efa97a958127f2971a0`。

## 待决定

1. 字体截图是否足以接受上述有限覆盖；若遮挡影响判断，应要求补拍。
2. 是否接受空应用约 8.69 MiB 的 libapp 增量。若接受这一产品成本，可考虑
   将增量上限设为 10 MiB（10,485,760 bytes），剩余 1,376,256 bytes，约
   15.1% 回归余量；这是待批准的工程建议，不是已有产品预算或通过结论。
   若成本不可接受，应先调查体积成因，不能仅为通过而抬高阈值。

确认后才配置阈值并执行 size_gate、接入 CI。当前不修改阈值、不标通过，
不触碰已冻结的性能实现。A10 与 whole 性能遗留项不受本报告替代。
