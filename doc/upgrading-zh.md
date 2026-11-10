# 从 1.0 升级

[English](upgrading.md) | **简体中文**

> 继续为已用 flutter_patcher 1.0.0 上线的 App 打补丁，并把项目升级到 1.1。

你有用 flutter_patcher 1.0.0 构建并已上线的 App，现在把项目升级到 1.1。补丁文件需要 flutter_patcher 1.1.0 或更新版本，所以已上线的 1.0.0 App 继续用 flutter_patcher 1.0.0+1 打补丁；项目、密钥和存储无需改动即可用于 1.1。

| 对象 | 1.1 的行为 |
|---|---|
| 已用 1.0.0 上线的 App | 它们的补丁用 flutter_patcher 1.0.0+1 生成、发布和撤回：在该版本的代码中，`pubspec.yaml` 依赖 `flutter_patcher: 1.0.0+1`。1.1 读取它们的基线时报 `PATCH_BASELINE_INCOMPATIBLE` |
| 项目 | `flutter_patcher.yaml` 继续可用：读取 `trust.patch`（忽略 `root` 和 `publisher`），`url`、`store`、`baseline_store`、`signing.command` 和各条命令的含义不变。密钥库中 1.0 的密钥包按补丁公钥查找。下一次 `build` 生成 1.1 App，并用该补丁密钥签名。1.0 中未完成的发布（`.dart_tool/flutter_patcher/publish-pending.json`）被 1.1 忽略，用 1.0.0+1 完成它 |
| 存储 | 1.0 的 `manifests/`、`objects/` 和 `catalog.json` 保留原位，继续为 1.0.0 App 提供服务。1.1 把 `.fptc` 文件写在存储根目录，与它们并列 |
| Dart API | 已删除：`SignedManifest`、`SignedUpdateResult`、`fetchSignedManifest`、`applySignedManifest`、`updatePublicationTrust`，因为它们所属的签名清单协议已被移除。App 自行获取的文件用 `applyPatchBytes` 或 `applyPatchFile`，放在 URL 下的文件用 `checkUpdate` 与 `applyPatch` |
| CLI | 已删除：`trust`、`publish --production` 与 `--request`（改为直接从存储中删除文件）、`keys import --rotate`，以及密钥角色 `root` 与 `publisher` |
| 显示的版本 | `currentVersion` 返回文件的序号（`seq`） |

## 相关

- [生产部署](production-playbook-zh.md)：用 1.1 构建上线版本并下发补丁。
- [更新日志](../CHANGELOG-zh.md)：1.1.0 的全部变化。
