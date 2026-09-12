# 文字字体替换真机验证

日期：2026-09-12。自动闭环 **4/4 passed**，视觉最终确认待用户审核。
这组用例补充此前仅 MaterialIcons 图标变化的覆盖，不以图标替换代替文字字体。

## 测试内容

同一字体族 `ReviewText`、同一路径 `fonts/review.ttf`，同一段英文大小写、
数字及标点。原版为 DejaVuSansMono，补丁替换文件为 DejaVuSerif-BoldItalic；
字体族、TextStyle 大小和内容保持不变，字重/斜体差异来自字体文件本身。
页面使用 SafeArea，避免先前状态栏遮挡。字体许可证随产物保存在 fonts/LICENSE。
不宣称中文字库、复杂文字排版、多字重选择或所有字体格式已经覆盖。

| 宿主 | 控制补丁 | 实际 tier | 自动结果 |
| --- | --- | --- | --- |
| standard | valid-lean | lean | passed |
| standard | valid-whole | whole | passed |
| custom | valid-lean | whole | passed |
| custom | valid-whole | whole | passed |

使用既有正式 build/patch/publish 和真机入口。每项验证下载、重启生效、资源
内容、binding、撤回后重启恢复，并保存三阶段截图。两组测试进程退出码均为 0。
字体专用构建省略了与本次目的无关的普通大小对照和 legacy APK；未更改产品代码。
既有标准矩阵入口的默认行为保持原样，新回退截图由 capture-rollback 显式启用。

## 证据

本地根目录：`.dart_tool/flutter_patcher/text-font-20260912/`。
远端：`/root/.flutter_patcher/text-font-20260912/`。
源码快照 SHA256：`ddbb94c6f42e45f4af1cd02f0ad085d6c4e43d82286168103c6cd4ed5bad12b9`。
快照包含本次未提交时的验收脚本修改，以逐文件哈希为准，不仅依赖 Git commit。
产物归档 SHA256：`3bc727b0e03e1795cdae0ee526b59f07a4415acc6dce144c05dca124c62efac4`。

- `inputs/result.json`：构建通过，四个补丁均携带完整非子集化 ReviewText；
  解包后的字体字节与替换 TTF 一致。下载后再次独立检查这项绑定。
- 两个宿主 APK 中的原字体哈希与 original.ttf 一致，APK 哈希与设备记录一致。
- `standard-device/result.json` SHA256：
  `8e6279d9bb0c9adf7e6885544dcdd52e18a86d22ff381bf3e03a9b272b242fbe`。
- `custom-device/result.json` SHA256：
  `b1c960fb1ef424b737fe54a9aad42bd9b96e0d687ae7ffc42144af2f72e29b72`。
- `review-result.json` 汇总四项自动检查和展示图片的 SHA256，
  visual_review 为 pending_user_confirmation。
- `font-review.html` 并排展示原版、补丁生效和撤回。custom 最后一张回退原图
  被系统通知遮住页头；另行补拍 clean 原图，核对同一进程原版/资源/binding/
  首帧状态，旧图保留，不作图片编辑。审核页使用 clean 图。

助手已查看截图，观察到等宽 → 粗斜体衬线 → 等宽的文字变化与恢复；
这不替代用户要求的最终视觉审核。自动断言证明状态、资源和字体文件身份，
不声称程序自动识别了屏幕上的字体样式。

首次 standard 安装因手机拒绝失败，日志保留；用户允许后安装成功。
未修改手机配置、未使用模拟器、未推送或发布。
性能实现保持冻结，体积门槛和 A10 不由本次测试替代。
